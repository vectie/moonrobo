import * as THREE from 'three'
import { TransformControls } from 'three/examples/jsm/controls/TransformControls.js'

export const URDF_TRANSFORM_DRAFT_EVENT = 'moonrobo:urdf-editor-transform-draft'
export const URDF_TRANSFORM_COMMIT_EVENT = 'moonrobo:urdf-editor-transform-commit'

const moonToThreeMatrix = new THREE.Matrix4().set(
  1, 0, 0, 0,
  0, 0, 1, 0,
  0, -1, 0, 0,
  0, 0, 0, 1,
)

function cleanNumber(value) {
  return Number.isFinite(value) ? Number(value.toFixed(6)) : 0
}

function formatNumber(value) {
  return cleanNumber(value).toFixed(3).replace(/\.?0+$/u, '')
}

function formatVector(value) {
  return `${formatNumber(value.x)} ${formatNumber(value.y)} ${formatNumber(value.z)}`
}

function formatRpy(value) {
  return `${formatNumber(value.roll)} ${formatNumber(value.pitch)} ${formatNumber(value.yaw)}`
}

function vecPayload(value) {
  return {
    x: cleanNumber(value.x),
    y: cleanNumber(value.y),
    z: cleanNumber(value.z),
  }
}

function rpyPayload(quaternion) {
  const euler = new THREE.Euler(0, 0, 0, 'ZYX').setFromQuaternion(quaternion, 'ZYX')
  return {
    roll: cleanNumber(euler.x),
    pitch: cleanNumber(euler.y),
    yaw: cleanNumber(euler.z),
  }
}

function basisPoseMatrix(pose) {
  if (!pose) return null
  const b = pose.world_basis || {}
  const moonMatrix = new THREE.Matrix4().set(
    Number(b.xx ?? 1),
    Number(b.xy ?? 0),
    Number(b.xz ?? 0),
    Number(pose.x || 0),
    Number(b.yx ?? 0),
    Number(b.yy ?? 1),
    Number(b.yz ?? 0),
    Number(pose.y || 0),
    Number(b.zx ?? 0),
    Number(b.zy ?? 0),
    Number(b.zz ?? 1),
    Number(pose.z || 0),
    0,
    0,
    0,
    1,
  )
  return new THREE.Matrix4().multiplyMatrices(moonToThreeMatrix, moonMatrix)
}

function parseScale(value) {
  const parts = String(value || '')
    .trim()
    .split(/\s+/)
    .map((part) => Number(part))
    .filter((part) => Number.isFinite(part) && part > 0)
  if (parts.length === 1) return new THREE.Vector3(parts[0], parts[0], parts[0])
  if (parts.length >= 3) return new THREE.Vector3(parts[0], parts[1], parts[2])
  return new THREE.Vector3(1, 1, 1)
}

function visualNodeId(visual) {
  return `visual:${String(visual.link_name || '')}:${Number(visual.index || 0)}`
}

function collisionNodeId(collision) {
  return `collision:${String(collision.link_name || '')}:${Number(collision.index || 0)}`
}

function inertialNodeId(inertial) {
  return `inertial:${String(inertial.link_name || '')}`
}

function selectedNodeKind(nodeId) {
  const [kind] = String(nodeId || '').split(':')
  return kind || ''
}

function selectedNodeName(nodeId) {
  const parts = String(nodeId || '').split(':')
  return parts.length >= 2 ? parts[1] : ''
}

function findRenderedVisual(robotGroup, nodeId) {
  for (const child of robotGroup.children) {
    if (child.userData?.moonroboEditorNodeId === nodeId) return child
  }
  return null
}

function makeButton(label, title, onClick) {
  const button = document.createElement('button')
  button.type = 'button'
  button.textContent = label
  button.title = title
  button.addEventListener('click', onClick)
  return button
}

function makeReadout() {
  const readout = document.createElement('span')
  readout.className = 'mesh-viewer-transform-readout'
  readout.textContent = 'No transform target'
  return readout
}

function makeToolbar(mount, setMode, reset, apply, revert) {
  const toolbar = document.createElement('div')
  toolbar.className = 'mesh-viewer-transform-tools'
  const move = makeButton('Move', 'Move selected URDF origin', () => setMode('translate'))
  const rotate = makeButton('Rotate', 'Rotate selected URDF origin', () => setMode('rotate'))
  const resetButton = makeButton('Reset', 'Reset transform preview', reset)
  const applyButton = makeButton('Apply', 'Apply transform preview to the URDF edit session', apply)
  const revertButton = makeButton('Revert', 'Revert transform preview in the viewport', revert)
  const readout = makeReadout()
  toolbar.append(move, rotate, resetButton, applyButton, revertButton, readout)
  mount.appendChild(toolbar)
  return { toolbar, move, rotate, resetButton, applyButton, revertButton, readout }
}

function originMatrix(origin) {
  const position = new THREE.Vector3(
    Number(origin?.x || 0),
    Number(origin?.y || 0),
    Number(origin?.z || 0),
  )
  const quaternion = new THREE.Quaternion().setFromEuler(
    new THREE.Euler(
      Number(origin?.roll || 0),
      Number(origin?.pitch || 0),
      Number(origin?.yaw || 0),
      'ZYX',
    ),
  )
  return new THREE.Matrix4().compose(position, quaternion, new THREE.Vector3(1, 1, 1))
}

export function createUrdfTransformEditor({
  mount,
  scene,
  camera,
  renderer,
  orbitControls,
  robotGroup,
}) {
  let viewport = { links: [], joints: [], visuals: [], visual_instances: [] }
  let activeTarget = null
  let mode = 'translate'
  let pendingTransform = false

  const proxy = new THREE.Group()
  proxy.name = 'moonrobo-urdf-origin-proxy'
  proxy.visible = false
  scene.add(proxy)

  const controls = new TransformControls(camera, renderer.domElement)
  controls.setMode(mode)
  controls.setSpace('local')
  controls.size = 0.58
  controls.enabled = false
  controls.visible = false
  const helper = controls.getHelper()
  helper.visible = false
  scene.add(helper)

  function setToolbarMode(nextMode) {
    mode = nextMode === 'rotate' ? 'rotate' : 'translate'
    controls.setMode(mode)
    mount.dataset.meshViewerTransformMode = mode
    buttons.move.classList.toggle('active', mode === 'translate')
    buttons.rotate.classList.toggle('active', mode === 'rotate')
  }

  function setStatus(status) {
    mount.dataset.meshViewerTransformStatus = status
  }

  function setPendingTransform(nextPending) {
    pendingTransform = Boolean(nextPending && activeTarget?.editable)
    mount.dataset.meshViewerTransformPending = String(pendingTransform)
    buttons.applyButton.disabled = !pendingTransform
    buttons.revertButton.disabled = !pendingTransform
  }

  function setToolbarEnabled(enabled) {
    buttons.move.disabled = !enabled
    buttons.rotate.disabled = !enabled
    buttons.resetButton.disabled = !enabled
    if (!enabled) setPendingTransform(false)
  }

  function setProxyMatrix(matrix) {
    const position = new THREE.Vector3()
    const quaternion = new THREE.Quaternion()
    const scale = new THREE.Vector3()
    matrix.decompose(position, quaternion, scale)
    proxy.position.copy(position)
    proxy.quaternion.copy(quaternion)
    proxy.scale.set(1, 1, 1)
    proxy.updateMatrixWorld(true)
  }

  function payloadForTarget(phase) {
    if (!activeTarget) return null
    proxy.updateMatrixWorld(true)

    const localMatrix = new THREE.Matrix4().copy(proxy.matrixWorld)
    if (activeTarget.parentWorldMatrix) {
      localMatrix.premultiply(new THREE.Matrix4().copy(activeTarget.parentWorldMatrix).invert())
    }

    const localPosition = new THREE.Vector3()
    const localQuaternion = new THREE.Quaternion()
    const localScale = new THREE.Vector3()
    localMatrix.decompose(localPosition, localQuaternion, localScale)

    const worldPosition = new THREE.Vector3()
    const worldQuaternion = new THREE.Quaternion()
    const worldScale = new THREE.Vector3()
    proxy.matrixWorld.decompose(worldPosition, worldQuaternion, worldScale)

    return {
      phase,
      nodeId: activeTarget.nodeId,
      sourceNodeId: activeTarget.sourceNodeId,
      kind: activeTarget.kind,
      mode,
      editable: activeTarget.editable,
      linkName: activeTarget.linkName,
      jointName: activeTarget.jointName,
      collisionIndex: activeTarget.collisionIndex,
      local: {
        xyz: vecPayload(localPosition),
        rpy: rpyPayload(localQuaternion),
      },
      world: {
        xyz: vecPayload(worldPosition),
        rpy: rpyPayload(worldQuaternion),
      },
    }
  }

  function emitTransform(eventName, phase) {
    const payload = payloadForTarget(phase)
    if (!payload) return
    mount.dataset.meshViewerTransformDraft = JSON.stringify(payload)
    window.dispatchEvent(new CustomEvent(eventName, { detail: payload }))
  }

  function updateReadout(phase = 'readout') {
    const payload = payloadForTarget(phase)
    const text = payload
      ? `xyz ${formatVector(payload.local.xyz)} rpy ${formatRpy(payload.local.rpy)}`
      : 'No transform target'
    buttons.readout.textContent = text
    mount.dataset.meshViewerTransformReadout = text
  }

  function applyProxyToPreviewObject() {
    if (!activeTarget?.previewObject || !activeTarget.scaleMatrix) return
    proxy.updateMatrixWorld(true)
    const parentWorld = activeTarget.previewObject.parent?.matrixWorld
    const localPose = parentWorld
      ? new THREE.Matrix4().copy(parentWorld).invert().multiply(proxy.matrixWorld)
      : new THREE.Matrix4().copy(proxy.matrixWorld)
    activeTarget.previewObject.matrix.copy(localPose.multiply(activeTarget.scaleMatrix))
    activeTarget.previewObject.matrixWorldNeedsUpdate = true
    activeTarget.previewObject.updateMatrixWorld(true)
  }

  function detach() {
    controls.detach()
    controls.enabled = false
    controls.visible = false
    helper.visible = false
    proxy.visible = false
    activeTarget = null
    mount.dataset.meshViewerTransformTargetNodeId = ''
    mount.dataset.meshViewerTransformTargetKind = ''
    mount.dataset.meshViewerTransformEditable = 'false'
    setToolbarEnabled(false)
    updateReadout()
  }

  function resetPreview() {
    if (!activeTarget) return
    setProxyMatrix(activeTarget.initialWorldMatrix)
    applyProxyToPreviewObject()
    setPendingTransform(false)
    updateReadout('reset')
    emitTransform(URDF_TRANSFORM_DRAFT_EVENT, 'reset')
  }

  function applyTransform() {
    if (!pendingTransform || !activeTarget?.editable) return
    updateReadout('commit')
    emitTransform(URDF_TRANSFORM_COMMIT_EVENT, 'commit')
    activeTarget.initialWorldMatrix = new THREE.Matrix4().copy(proxy.matrixWorld)
    setPendingTransform(false)
    setStatus('applied')
  }

  function revertPreview() {
    if (!activeTarget) return
    resetPreview()
    setStatus(activeTarget.editable ? 'ready' : 'read-only')
  }

  const buttons = makeToolbar(
    mount, setToolbarMode, resetPreview, applyTransform, revertPreview,
  )
  setToolbarMode(mode)
  setToolbarEnabled(false)

  function linkMap() {
    return new Map((viewport.links || []).map((link) => [String(link.name || ''), link]))
  }

  function jointMap() {
    return new Map((viewport.joints || []).map((joint) => [String(joint.name || ''), joint]))
  }

  function linkWorldMatrix(linkName) {
    return basisPoseMatrix(linkMap().get(String(linkName || '')))
  }

  function visualTarget(nodeId, selectedObject) {
    const visual = (viewport.visuals || []).find((item) => visualNodeId(item) === nodeId)
    const instance = (viewport.visual_instances || []).find((item) => visualNodeId(item) === nodeId)
    if (!visual || !instance) return null
    const links = linkMap()
    const parentWorldMatrix = basisPoseMatrix(links.get(String(visual.link_name || '')))
    const initialWorldMatrix = basisPoseMatrix(instance)
    if (!initialWorldMatrix) return null
    const scale = parseScale(visual.mesh_scale)
    return {
      nodeId,
      sourceNodeId: nodeId,
      kind: 'visual-origin',
      editable: true,
      linkName: String(visual.link_name || ''),
      jointName: '',
      initialWorldMatrix,
      parentWorldMatrix,
      previewObject: selectedObject || findRenderedVisual(robotGroup, nodeId),
      scaleMatrix: new THREE.Matrix4().makeScale(scale.x, scale.y, scale.z),
    }
  }

  function linkTarget(nodeId) {
    const name = selectedNodeName(nodeId)
    const links = linkMap()
    const link = links.get(name)
    if (!link) return null
    const initialWorldMatrix = basisPoseMatrix(link)
    if (!initialWorldMatrix) return null
    const parent = link.parent_link ? links.get(String(link.parent_link || '')) : null
    const parentWorldMatrix = parent ? basisPoseMatrix(parent) : null
    const parentJoint = String(link.parent_joint || '')
    return {
      nodeId,
      sourceNodeId: parentJoint ? `joint:${parentJoint}` : nodeId,
      kind: parentJoint ? 'joint-origin' : 'link-origin',
      editable: Boolean(parentJoint && parentWorldMatrix),
      linkName: name,
      jointName: parentJoint,
      initialWorldMatrix,
      parentWorldMatrix,
      previewObject: null,
      scaleMatrix: null,
    }
  }

  function jointTarget(nodeId) {
    const name = selectedNodeName(nodeId)
    const joint = jointMap().get(name)
    if (!joint?.child_link) return null
    return {
      ...linkTarget(`link:${joint.child_link}`),
      nodeId,
      sourceNodeId: nodeId,
      kind: 'joint-origin',
      editable: true,
      jointName: name,
    }
  }

  function collisionTarget(nodeId, selectedObject) {
    const collision = (viewport.collisions || []).find((item) => collisionNodeId(item) === nodeId)
    if (!collision) return null
    const parentWorldMatrix = linkWorldMatrix(collision.link_name)
    if (!parentWorldMatrix) return null
    const initialWorldMatrix = new THREE.Matrix4()
      .copy(parentWorldMatrix)
      .multiply(originMatrix(collision.origin))
    const scale = parseScale(collision.mesh_scale)
    return {
      nodeId,
      sourceNodeId: nodeId,
      kind: 'collision-origin',
      editable: true,
      linkName: String(collision.link_name || ''),
      jointName: '',
      collisionIndex: String(Number(collision.index || 0)),
      initialWorldMatrix,
      parentWorldMatrix,
      previewObject: selectedObject || findRenderedVisual(robotGroup, nodeId),
      scaleMatrix: collision.geometry_kind === 'mesh'
        ? new THREE.Matrix4().makeScale(scale.x, scale.y, scale.z)
        : new THREE.Matrix4().identity(),
    }
  }

  function inertialTarget(nodeId) {
    const inertial = (viewport.inertials || []).find((item) => inertialNodeId(item) === nodeId)
    if (!inertial) return null
    const parentWorldMatrix = linkWorldMatrix(inertial.link_name)
    if (!parentWorldMatrix) return null
    const initialWorldMatrix = new THREE.Matrix4()
      .copy(parentWorldMatrix)
      .multiply(originMatrix(inertial.origin))
    return {
      nodeId,
      sourceNodeId: nodeId,
      kind: 'inertial-origin',
      editable: true,
      linkName: String(inertial.link_name || ''),
      jointName: '',
      collisionIndex: '',
      initialWorldMatrix,
      parentWorldMatrix,
      previewObject: null,
      scaleMatrix: null,
    }
  }

  function resolveTarget(nodeId, selectedObject) {
    const kind = selectedNodeKind(nodeId)
    if (kind === 'visual') return visualTarget(nodeId, selectedObject)
    if (kind === 'link') return linkTarget(nodeId)
    if (kind === 'joint') return jointTarget(nodeId)
    if (kind === 'collision') return collisionTarget(nodeId, selectedObject)
    if (kind === 'inertial') return inertialTarget(nodeId)
    return null
  }

  function setSelection(nodeId, selectedObject = null) {
    const target = resolveTarget(String(nodeId || '').trim(), selectedObject)
    if (!target?.initialWorldMatrix) {
      detach()
      setStatus(nodeId ? 'unsupported-selection' : 'idle')
      return null
    }

    activeTarget = target
    setProxyMatrix(target.initialWorldMatrix)
    proxy.visible = true
    controls.attach(proxy)
    controls.enabled = true
    controls.visible = true
    helper.visible = true
    mount.dataset.meshViewerTransformTargetNodeId = target.nodeId
    mount.dataset.meshViewerTransformSourceNodeId = target.sourceNodeId
    mount.dataset.meshViewerTransformTargetKind = target.kind
    mount.dataset.meshViewerTransformEditable = String(target.editable)
    setStatus(target.editable ? 'ready' : 'read-only')
    setToolbarEnabled(true)
    setPendingTransform(false)
    updateReadout('select')
    emitTransform(URDF_TRANSFORM_DRAFT_EVENT, 'select')
    return target
  }

  controls.addEventListener('dragging-changed', (event) => {
    const dragging = Boolean(event.value)
    orbitControls.enabled = !dragging
    mount.dataset.meshViewerTransformDragging = String(dragging)
    if (!dragging && activeTarget) setStatus(activeTarget.editable ? 'preview-pending' : 'read-only')
  })

  controls.addEventListener('objectChange', () => {
    if (!activeTarget) return
    applyProxyToPreviewObject()
    setPendingTransform(true)
    updateReadout('preview')
    emitTransform(URDF_TRANSFORM_DRAFT_EVENT, 'preview')
  })

  return {
    setViewport(nextViewport) {
      viewport = nextViewport || viewport
    },
    setSelection,
    isDragging() {
      return Boolean(controls.dragging)
    },
    dispose() {
      detach()
      helper.parent?.remove(helper)
      proxy.parent?.remove(proxy)
      buttons.toolbar.remove()
      controls.dispose()
    },
  }
}

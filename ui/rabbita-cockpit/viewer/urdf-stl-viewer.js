import * as THREE from 'three'
import { OrbitControls } from 'three/examples/jsm/controls/OrbitControls.js'
import { loadStlGeometry } from './stl-geometry.js'

const viewerRegistry = new WeakMap()
let activeViewer = null
let activeRunId = 0
const EDITOR_SELECT_EVENT = 'moonrobo:urdf-editor-select'
const EDITOR_SELECTION_CHANGED_EVENT = 'moonrobo:urdf-editor-selection-changed'

const state = {
  loadedMeshes: 0,
  totalMeshes: 0,
  failedMeshes: 0,
  removedTriangles: 0,
  renderedFrames: 0,
  status: 'idle',
  error: '',
  bounds: null,
  selectedNodeId: '',
}

window.__moonroboMeshViewerState = state

function setStatus(mount, text) {
  state.status = text
  mount.dataset.meshViewerStatus = text
  let node = mount.querySelector('.mesh-viewer-status')
  if (!node) {
    node = document.createElement('div')
    node.className = 'mesh-viewer-status'
    mount.appendChild(node)
  }
  node.textContent = text
}

function encodePath(path) {
  return path
    .split('/')
    .filter((segment) => segment && segment !== '.')
    .map((segment) => encodeURIComponent(segment))
    .join('/')
}

function normalizePath(path) {
  const parts = []
  for (const raw of String(path || '').split('/')) {
    if (!raw || raw === '.') continue
    if (raw === '..') {
      parts.pop()
      continue
    }
    parts.push(raw)
  }
  return parts.join('/')
}

function dirname(path) {
  const index = path.lastIndexOf('/')
  return index < 0 ? '' : path.slice(0, index)
}

function meshAssetPath(viewport, visual) {
  const resolved = normalizePath(String(visual.resolved_mesh_path || ''))
  if (resolved) return `/api/robobook/assets/${encodePath(resolved)}`
  const filename = String(visual.mesh_filename || '')
  if (!filename || /^(https?:|file:|package:)/i.test(filename)) return ''
  return `/api/robobook/assets/${encodePath(
    normalizePath(`${dirname(String(viewport.source_path || ''))}/${filename}`),
  )}`
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

const moonToThreeMatrix = new THREE.Matrix4().set(
  1, 0, 0, 0,
  0, 0, 1, 0,
  0, -1, 0, 0,
  0, 0, 0, 1,
)

function visualTransformMatrix(instance, scale) {
  const b = instance.world_basis || {}
  const moonMatrix = new THREE.Matrix4().set(
    Number(b.xx ?? 1),
    Number(b.xy ?? 0),
    Number(b.xz ?? 0),
    Number(instance.x || 0),
    Number(b.yx ?? 0),
    Number(b.yy ?? 1),
    Number(b.yz ?? 0),
    Number(instance.y || 0),
    Number(b.zx ?? 0),
    Number(b.zy ?? 0),
    Number(b.zz ?? 1),
    Number(instance.z || 0),
    0,
    0,
    0,
    1,
  )
  const scaleMatrix = new THREE.Matrix4().makeScale(scale.x, scale.y, scale.z)
  return new THREE.Matrix4().multiplyMatrices(moonToThreeMatrix, moonMatrix).multiply(scaleMatrix)
}

function buildVisuals(viewport) {
  const instances = new Map()
  for (const instance of viewport.visual_instances || []) {
    instances.set(Number(instance.index), instance)
  }
  return (viewport.visuals || [])
    .map((visual) => ({
      visual,
      instance: instances.get(Number(visual.index)),
      url: meshAssetPath(viewport, visual),
    }))
    .filter(({ visual, instance, url }) => {
      return visual.geometry_kind === 'mesh' && visual.asset_status === 'resolved' && instance && url
    })
}

function visualEditorNodeId(visual) {
  return `visual:${String(visual.link_name || '')}:${Number(visual.index || 0)}`
}

function tagVisualObject(object, visual) {
  object.userData.moonroboEditorNodeId = visualEditorNodeId(visual)
  object.userData.parentLinkName = String(visual.link_name || '')
  object.userData.geometryRole = 'visual'
  object.userData.isVisualMesh = true
  object.userData.visualObjectIndex = Number(visual.index || 0)
}

function editorNodeIdForObject(object) {
  let current = object
  while (current) {
    const nodeId = current.userData?.moonroboEditorNodeId
    if (typeof nodeId === 'string' && nodeId.trim()) return nodeId
    current = current.parent
  }
  return ''
}

function materialList(material) {
  return Array.isArray(material) ? material : [material]
}

function setMaterialSelected(material, selected) {
  if (!material) return
  const data = material.userData || (material.userData = {})
  if (!data.moonroboBaseMaterial) {
    data.moonroboBaseMaterial = {
      color: material.color?.isColor ? material.color.getHex() : null,
      emissive: material.emissive?.isColor ? material.emissive.getHex() : null,
      emissiveIntensity: Number(material.emissiveIntensity || 0),
      opacity: Number(material.opacity ?? 1),
      transparent: Boolean(material.transparent),
      depthWrite: material.depthWrite !== false,
    }
  }
  const base = data.moonroboBaseMaterial
  if (selected) {
    if (material.color?.isColor) material.color.set(0xf7b84b)
    if (material.emissive?.isColor) {
      material.emissive.set(0x2563eb)
      material.emissiveIntensity = 0.46
    }
    material.transparent = true
    material.opacity = Math.max(0.92, base.opacity || 1)
    material.depthWrite = true
  } else {
    if (base.color !== null && material.color?.isColor) material.color.setHex(base.color)
    if (base.emissive !== null && material.emissive?.isColor) material.emissive.setHex(base.emissive)
    if ('emissiveIntensity' in material) material.emissiveIntensity = base.emissiveIntensity
    material.opacity = base.opacity
    material.transparent = base.transparent
    material.depthWrite = base.depthWrite
  }
  material.needsUpdate = true
}

function setObjectSelected(object, selected) {
  object.userData.moonroboSelected = selected
  object.traverse((child) => {
    if (!child.isMesh) return
    for (const material of materialList(child.material)) {
      setMaterialSelected(material, selected)
    }
  })
}

function selectedBoxForObject(object) {
  object.updateMatrixWorld(true)
  const box = new THREE.Box3().setFromObject(object)
  return box.isEmpty() ? null : box
}

function applyEditorSelection(mount, robotGroup, nodeId) {
  const selectedNodeId = String(nodeId || '').trim()
  const selectedBox = new THREE.Box3()
  let selectedCount = 0
  for (const child of robotGroup.children) {
    const selected = editorNodeIdForObject(child) === selectedNodeId
    setObjectSelected(child, selected)
    if (selected) {
      const box = selectedBoxForObject(child)
      if (box) selectedBox.union(box)
      selectedCount += 1
    }
  }
  state.selectedNodeId = selectedNodeId
  mount.dataset.meshViewerSelectedNodeId = selectedNodeId
  mount.dataset.meshViewerSelectedMeshes = String(selectedCount)
  return selectedBox.isEmpty() ? null : selectedBox
}

function focusCameraOnBox(camera, controls, box) {
  if (!box || box.isEmpty()) return
  const center = box.getCenter(new THREE.Vector3())
  const size = box.getSize(new THREE.Vector3())
  const currentOffset = camera.position.clone().sub(controls.target)
  const radius = Math.max(size.x, size.y, size.z, 0.08)
  if (currentOffset.length() < 0.1) currentOffset.set(1.4, -2.4, 1.2)
  currentOffset.setLength(Math.max(currentOffset.length(), radius * 3.8))
  controls.target.copy(center)
  camera.position.copy(center).add(currentOffset)
  camera.updateProjectionMatrix()
  controls.update()
}

function materialFor(index) {
  const colors = [0x60786f, 0x3f6f8f, 0x99733a, 0x6b7285, 0x765f53, 0x4f8060]
  return new THREE.MeshStandardMaterial({
    color: colors[index % colors.length],
    roughness: 0.62,
    metalness: 0.08,
    side: THREE.DoubleSide,
  })
}

function makeRenderer(mount) {
  const renderer = new THREE.WebGLRenderer({
    antialias: true,
    preserveDrawingBuffer: true,
  })
  renderer.setClearColor(0xf4f6f3, 1)
  renderer.outputColorSpace = THREE.SRGBColorSpace
  renderer.toneMapping = THREE.NeutralToneMapping
  mount.appendChild(renderer.domElement)
  return renderer
}

function resize(mount, renderer, camera) {
  const width = Math.max(1, mount.clientWidth)
  const height = Math.max(1, mount.clientHeight)
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2))
  renderer.setSize(width, height, false)
  camera.aspect = width / height
  camera.updateProjectionMatrix()
}

function addSceneBasics(scene) {
  scene.add(new THREE.HemisphereLight(0xffffff, 0xb6c2bd, 1.7))
  const key = new THREE.DirectionalLight(0xffffff, 2.2)
  key.position.set(4, -5, 6)
  scene.add(key)
  const fill = new THREE.DirectionalLight(0xdceef5, 0.8)
  fill.position.set(-4, 3, 3)
  scene.add(fill)

  const grid = new THREE.GridHelper(6, 36, 0x9aaba4, 0xdbe3df)
  grid.material.transparent = true
  grid.material.opacity = 0.55
  scene.add(grid)

  const axes = new THREE.AxesHelper(0.35)
  axes.position.set(-0.45, 0.01, 0.45)
  scene.add(axes)
}

function fitCameraToBox(camera, controls, box, target) {
  if (box.isEmpty()) {
    state.bounds = null
    camera.position.set(1.4, -2.4, 1.2)
    controls.target.set(0, 0, 0.2)
    controls.update()
    return false
  }
  const size = box.getSize(new THREE.Vector3())
  const center = box.getCenter(new THREE.Vector3())
  state.bounds = {
    min: box.min.toArray(),
    max: box.max.toArray(),
    size: size.toArray(),
    center: center.toArray(),
  }
  if (target) target.userData.bounds = state.bounds
  const radius = Math.max(size.x, size.y, size.z, 0.2)
  camera.near = Math.max(radius / 500, 0.001)
  camera.far = Math.max(radius * 80, 50)
  camera.position.set(center.x + radius * 1.1, center.y + radius * 0.9, center.z + radius * 2.1)
  controls.target.copy(center)
  camera.updateProjectionMatrix()
  controls.update()
  const cameraState = {
    position: camera.position.toArray(),
    target: controls.target.toArray(),
    near: camera.near,
    far: camera.far,
  }
  if (target) target.userData.camera = cameraState
  return true
}

function fitCamera(camera, controls, object) {
  object.updateMatrixWorld(true)
  const box = new THREE.Box3().setFromObject(object)
  return fitCameraToBox(camera, controls, box, object)
}

function cameraCacheKey(viewport) {
  return [
    'moonrobo.meshViewer.bounds',
    String(viewport.source_path || ''),
    String(viewport.root_link || ''),
    String((viewport.visuals || []).length),
  ].join(':')
}

function boxFromBounds(bounds) {
  if (!bounds?.min || !bounds?.max) return null
  const box = new THREE.Box3(new THREE.Vector3().fromArray(bounds.min), new THREE.Vector3().fromArray(bounds.max))
  return box.isEmpty() ? null : box
}

function readCachedBounds(viewport) {
  try {
    return boxFromBounds(JSON.parse(window.localStorage.getItem(cameraCacheKey(viewport)) || 'null'))
  } catch (_error) {
    return null
  }
}

function writeCachedBounds(viewport, bounds) {
  if (!bounds) return
  try {
    window.localStorage.setItem(cameraCacheKey(viewport), JSON.stringify(bounds))
  } catch (_error) {
    // Rendering should continue even if browser storage is unavailable.
  }
}

function estimateViewportBox(viewport) {
  const box = new THREE.Box3()
  const addInstance = (instance, scale) => {
    if (!instance) return
    const matrix = visualTransformMatrix(instance, scale || new THREE.Vector3(1, 1, 1))
    box.expandByPoint(new THREE.Vector3().setFromMatrixPosition(matrix))
  }

  for (const { visual, instance } of buildVisuals(viewport)) {
    addInstance(instance, parseScale(visual.mesh_scale))
  }
  for (const link of viewport.links || []) {
    addInstance(link)
  }

  if (box.isEmpty()) return null
  box.expandByScalar(0.32)
  return box
}

function fitInitialCamera(mount, camera, controls, viewport, robotGroup) {
  const cached = readCachedBounds(viewport)
  const box = cached || estimateViewportBox(viewport)
  const fitted = box ? fitCameraToBox(camera, controls, box, robotGroup) : fitCamera(camera, controls, robotGroup)
  mount.dataset.meshViewerCameraReady = String(fitted)
  mount.dataset.meshViewerCameraSource = cached ? 'cache' : 'estimate'
  mount.dataset.meshViewerBounds = JSON.stringify(robotGroup.userData.bounds || null)
  mount.dataset.meshViewerCamera = JSON.stringify(robotGroup.userData.camera || null)
  return fitted
}

function dispose(viewer) {
  if (!viewer || viewer.disposed) return
  viewer.disposed = true
  if (viewer.canvas && viewer.clickHandler) {
    viewer.canvas.removeEventListener('click', viewer.clickHandler)
  }
  if (viewer.selectionChangedHandler) {
    window.removeEventListener(EDITOR_SELECTION_CHANGED_EVENT, viewer.selectionChangedHandler)
  }
  viewer.resizeObserver.disconnect()
  viewer.controls.dispose()
  viewer.renderer.dispose()
}

async function loadMeshes(mount, robotGroup, viewport, runId) {
  const visuals = buildVisuals(viewport)
  state.loadedMeshes = 0
  state.failedMeshes = 0
  state.removedTriangles = 0
  state.totalMeshes = visuals.length
  state.error = ''
  mount.dataset.meshViewerRevealed = '0'

  for (const { visual, instance, url } of visuals) {
    if (runId !== activeRunId) return
    setStatus(mount, `Loading STL ${state.loadedMeshes}/${visuals.length}`)
    try {
      const { geometry, removedTriangles } = await loadStlGeometry(url)
      if (runId !== activeRunId) return
      state.removedTriangles += removedTriangles

      const mesh = new THREE.Mesh(geometry, materialFor(Number(visual.index)))
      mesh.castShadow = true
      mesh.receiveShadow = true
      tagVisualObject(mesh, visual)
      for (const material of materialList(mesh.material)) {
        setMaterialSelected(material, visualEditorNodeId(visual) === state.selectedNodeId)
      }

      const group = new THREE.Group()
      group.matrixAutoUpdate = false
      group.matrix.copy(visualTransformMatrix(instance, parseScale(visual.mesh_scale)))
      tagVisualObject(group, visual)
      group.add(mesh)
      robotGroup.add(group)
      state.loadedMeshes += 1
      mount.dataset.meshViewerRevealed = String(state.loadedMeshes)
      mount.dataset.meshViewerLoaded = String(state.loadedMeshes)
      mount.dataset.meshViewerRepaired = String(state.removedTriangles)
      setStatus(mount, `Rendering STL ${state.loadedMeshes}/${visuals.length}`)
    } catch (error) {
      state.failedMeshes += 1
      state.error = error instanceof Error ? error.message : String(error)
    }
  }

  setStatus(
    mount,
    `${viewport.root_link || 'robot'}: ${state.loadedMeshes}/${state.totalMeshes} STL meshes${
      state.removedTriangles > 0 ? `, ${state.removedTriangles} repaired triangles` : ''
    }`,
  )
}

async function mountViewer(mount) {
  if (viewerRegistry.has(mount)) return
  activeRunId += 1
  const runId = activeRunId
  dispose(activeViewer)

  mount.classList.add('is-loading')
  setStatus(mount, 'Loading snapshot')

  const renderer = makeRenderer(mount)
  const scene = new THREE.Scene()
  scene.background = new THREE.Color(0xf4f6f3)
  addSceneBasics(scene)

  const camera = new THREE.PerspectiveCamera(42, 1, 0.001, 100)
  const controls = new OrbitControls(camera, renderer.domElement)
  controls.enableDamping = true
  controls.dampingFactor = 0.06
  controls.screenSpacePanning = true

  const robotGroup = new THREE.Group()
  const raycaster = new THREE.Raycaster()
  const pointer = new THREE.Vector2()
  mount.dataset.meshViewerRevealMode = 'camera-first-progressive-stl'
  mount.dataset.meshViewerCameraReady = 'false'
  scene.add(robotGroup)

  const resizeObserver = new ResizeObserver(() => resize(mount, renderer, camera))
  resizeObserver.observe(mount)
  resize(mount, renderer, camera)

  const viewer = { renderer, controls, resizeObserver, disposed: false }
  activeViewer = viewer
  viewerRegistry.set(mount, viewer)

  function applySelection(nodeId, focus = false) {
    const box = applyEditorSelection(mount, robotGroup, nodeId)
    if (focus) focusCameraOnBox(camera, controls, box)
  }

  function onSelectionChanged(event) {
    const nodeId = event?.detail?.nodeId
    applySelection(nodeId, event?.detail?.focus !== false)
  }

  window.addEventListener(EDITOR_SELECTION_CHANGED_EVENT, onSelectionChanged)
  viewer.selectionChangedHandler = onSelectionChanged

  function selectFromPointer(event) {
    const rect = renderer.domElement.getBoundingClientRect()
    if (rect.width <= 0 || rect.height <= 0) return
    pointer.x = ((event.clientX - rect.left) / rect.width) * 2 - 1
    pointer.y = -((event.clientY - rect.top) / rect.height) * 2 + 1
    raycaster.setFromCamera(pointer, camera)
    const hits = raycaster.intersectObjects(robotGroup.children, true)
    for (const hit of hits) {
      const nodeId = editorNodeIdForObject(hit.object)
      if (!nodeId) continue
      state.selectedNodeId = nodeId
      mount.dataset.meshViewerSelectedNodeId = nodeId
      applySelection(nodeId, false)
      window.dispatchEvent(
        new CustomEvent(EDITOR_SELECT_EVENT, {
          detail: { nodeId },
        }),
      )
      return
    }
  }

  renderer.domElement.addEventListener('click', selectFromPointer)
  viewer.canvas = renderer.domElement
  viewer.clickHandler = selectFromPointer

  function frame() {
    if (viewer.disposed || runId !== activeRunId || !document.body.contains(mount)) {
      dispose(viewer)
      return
    }
    controls.update()
    renderer.render(scene, camera)
    mount.dataset.meshViewerTriangles = String(renderer.info.render.triangles)
    mount.dataset.meshViewerCalls = String(renderer.info.render.calls)
    state.renderedFrames += 1
    requestAnimationFrame(frame)
  }
  requestAnimationFrame(frame)

  try {
    const response = await fetch('/api/cockpit/snapshot', { cache: 'no-store' })
    if (!response.ok) throw new Error(`snapshot ${response.status}`)
    const snapshot = await response.json()
    const viewport = snapshot.model_viewport || {}
    fitInitialCamera(mount, camera, controls, viewport, robotGroup)
    renderer.render(scene, camera)
    await loadMeshes(mount, robotGroup, viewport, runId)
    applySelection(state.selectedNodeId, false)
    if (runId !== activeRunId) return
    robotGroup.updateMatrixWorld(true)
    const actualBox = new THREE.Box3().setFromObject(robotGroup)
    if (!actualBox.isEmpty()) {
      const size = actualBox.getSize(new THREE.Vector3())
      const center = actualBox.getCenter(new THREE.Vector3())
      robotGroup.userData.actualBounds = {
        min: actualBox.min.toArray(),
        max: actualBox.max.toArray(),
        size: size.toArray(),
        center: center.toArray(),
      }
      mount.dataset.meshViewerActualBounds = JSON.stringify(robotGroup.userData.actualBounds)
      writeCachedBounds(viewport, robotGroup.userData.actualBounds)
    }
    renderer.render(scene, camera)
    mount.classList.remove('is-loading')
    mount.classList.add('is-ready')
  } catch (error) {
    state.error = error instanceof Error ? error.message : String(error)
    mount.classList.remove('is-loading')
    mount.classList.add('is-error')
    setStatus(mount, `Mesh render error: ${state.error}`)
  }
}

function mountAllViewers() {
  document.querySelectorAll('.moonrobo-mesh-viewer').forEach((mount) => mountViewer(mount))
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', mountAllViewers, { once: true })
} else {
  mountAllViewers()
}

new MutationObserver(mountAllViewers).observe(document.documentElement, {
  childList: true,
  subtree: true,
})

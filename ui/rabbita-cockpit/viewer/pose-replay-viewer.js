import * as THREE from 'three'
import { OrbitControls } from 'three/examples/jsm/controls/OrbitControls.js'
import { OBJLoader } from 'three/examples/jsm/loaders/OBJLoader.js'
import { STLLoader } from 'three/examples/jsm/loaders/STLLoader.js'
import { POSE_REPLAY_LIMITS, validatePoseFrame, validatePoseModel } from './pose-replay-channel.js'

const MAX_ASSET_BYTES = 32 * 1024 * 1024
const MAX_MODEL_ASSET_BYTES = 128 * 1024 * 1024
const MAX_ASSET_VERTICES = 1500000
const TRACK_COLORS = { physics: 0x3169ad, reference: 0xb56a08 }

function aborted() {
  return new DOMException('Replay model load was superseded', 'AbortError')
}

function primitiveGeometry(shape) {
  switch (shape.kind) {
    case 'box': return new THREE.BoxGeometry(...shape.size)
    case 'sphere': return new THREE.SphereGeometry(shape.radius, 20, 12)
    case 'ellipsoid': return new THREE.SphereGeometry(1, 20, 12).scale(...shape.radii)
    case 'cylinder': return new THREE.CylinderGeometry(shape.radius, shape.radius, shape.length, 20).rotateX(Math.PI / 2)
    case 'capsule': return new THREE.CapsuleGeometry(shape.radius, shape.length, 8, 16).rotateX(Math.PI / 2)
    // MuJoCo planes with zero extent are infinite. This is a display patch,
    // not a replacement collision plane; its local pose is still respected.
    case 'plane': return new THREE.PlaneGeometry(shape.size[0] || 20, shape.size[1] || 20)
    default: throw new Error(`Unsupported primitive ${shape.kind}`)
  }
}

function disposeMaterials(material) {
  for (const entry of Array.isArray(material) ? material : [material]) entry?.dispose()
}

function validateMeshGeometry(geometry, vertexBudget) {
  const position = geometry.getAttribute('position')
  if (!position || position.itemSize !== 3 || position.count < 3) throw new Error('Mesh contains no triangles')
  vertexBudget.count += position.count
  if (vertexBudget.count > MAX_ASSET_VERTICES) throw new Error('Mesh exceeds the vertex budget')
  for (const component of position.array) {
    if (!Number.isFinite(component) || Math.abs(component) > 1e6) throw new Error('Mesh contains an invalid vertex')
  }
  const index = geometry.getIndex()
  if ((index ? index.count : position.count) % 3 !== 0) throw new Error('Mesh triangle indices are incomplete')
  if (index) {
    for (const entry of index.array) if (entry < 0 || entry >= position.count) throw new Error('Mesh triangle index is out of range')
  }
  const normals = geometry.getAttribute('normal')
  if (!normals || normals.count !== position.count || normals.array.some((component) => !Number.isFinite(component))) {
    geometry.deleteAttribute('normal')
    geometry.computeVertexNormals()
  }
  // Replay materials do not use UVs or textures. Discard optional attributes
  // rather than passing malformed unused data to WebGL.
  for (const name of Object.keys(geometry.attributes)) {
    if (name !== 'position' && name !== 'normal') geometry.deleteAttribute(name)
  }
  geometry.computeBoundingBox()
  geometry.computeBoundingSphere()
  return geometry
}

function parseMesh(bytes, asset) {
  const result = []
  const budget = { count: 0 }
  let parsed = null
  try {
    if (asset.endsWith('.stl')) {
      const geometry = new STLLoader().parse(bytes.buffer)
      result.push(geometry)
      validateMeshGeometry(geometry, budget)
    } else {
      parsed = new OBJLoader().parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes))
      parsed.updateMatrixWorld(true)
      parsed.traverse((object) => {
        if (!object.isMesh) return
        const geometry = object.geometry.clone().applyMatrix4(object.matrixWorld)
        result.push(geometry)
        validateMeshGeometry(geometry, budget)
      })
      if (!result.length) throw new Error('OBJ contains no triangle mesh')
    }
    return result
  } catch (error) {
    for (const geometry of result) geometry.dispose()
    throw error
  } finally {
    parsed?.traverse((object) => {
      object.geometry?.dispose()
      disposeMaterials(object.material)
    })
  }
}

async function readBoundedAsset(response, budget, signal) {
  const declared = Number(response.headers.get('content-length'))
  if (Number.isFinite(declared) && declared > MAX_ASSET_BYTES) throw new Error('Replay mesh exceeds 32 MiB')
  let count = 0
  const chunks = []
  const reader = response.body?.getReader()
  if (reader) {
    try {
      while (true) {
        if (signal.aborted) throw aborted()
        const { done, value } = await reader.read()
        if (done) break
        count += value.byteLength
        budget.bytes += value.byteLength
        if (count > MAX_ASSET_BYTES || budget.bytes > MAX_MODEL_ASSET_BYTES) throw new Error('Replay mesh byte budget exceeded')
        chunks.push(value)
      }
    } catch (error) {
      await reader.cancel().catch(() => {})
      throw error
    } finally {
      reader.releaseLock()
    }
  } else {
    const bytes = new Uint8Array(await response.arrayBuffer())
    count = bytes.byteLength
    budget.bytes += count
    if (count > MAX_ASSET_BYTES || budget.bytes > MAX_MODEL_ASSET_BYTES) throw new Error('Replay mesh byte budget exceeded')
    chunks.push(bytes)
  }
  const bytes = new Uint8Array(count)
  let offset = 0
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength }
  return bytes
}

function applyPose(object, position, quaternion) {
  object.position.set(...position)
  object.quaternion.set(quaternion[1], quaternion[2], quaternion[3], quaternion[0])
}

// All body poses are absolute MuJoCo world poses. The only Z-up -> Y-up
// conversion is on this viewer's world group; body parent metadata is used for
// diagnostic skeleton edges, never for transform parenting.
export function createPoseReplayViewer({ mount, resolveAssetUrl, allowedAssetOrigins = [], onStatus = () => {}, dark = false, followTheme = false }) {
  if (!(mount instanceof HTMLElement)) throw new TypeError('A replay viewer mount element is required')
  if (typeof resolveAssetUrl !== 'function') throw new TypeError('A replay mesh asset resolver is required')
  const approvedOrigins = new Set([window.location.origin])
  for (const origin of allowedAssetOrigins) approvedOrigins.add(new URL(origin, window.location.href).origin)
  const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: false, powerPreference: 'low-power' })
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2))
  renderer.outputColorSpace = THREE.SRGBColorSpace
  renderer.domElement.className = 'pose-replay-canvas'
  renderer.domElement.tabIndex = 0
  renderer.domElement.setAttribute('role', 'img')
  renderer.domElement.setAttribute('aria-label', 'Experiment 3D replay. Drag to orbit, scroll to zoom, and use arrow keys to pan the camera.')
  renderer.domElement.style.display = 'block'
  renderer.domElement.style.width = '100%'
  renderer.domElement.style.height = '100%'
  mount.appendChild(renderer.domElement)
  const scene = new THREE.Scene()
  scene.background = new THREE.Color(dark ? 0x080b0d : 0xffffff)
  scene.add(new THREE.HemisphereLight(0xffffff, 0xb6c2bd, 2))
  const key = new THREE.DirectionalLight(0xffffff, 2.4)
  key.position.set(3, 6, 4)
  scene.add(key)
  let grid = new THREE.GridHelper(20, 40, dark ? 0x283331 : 0xe3e3e5, dark ? 0x18211f : 0xf0f0f2)
  grid.position.y = -0.002
  scene.add(grid)
  const world = new THREE.Group()
  world.rotation.x = -Math.PI / 2
  scene.add(world)
  const camera = new THREE.PerspectiveCamera(42, 1, 0.005, 1000)
  camera.position.set(3.4, 2.2, 3.6)
  const controls = new OrbitControls(camera, renderer.domElement)
  controls.target.set(0, 0.8, 0)
  controls.enableDamping = false
  controls.minDistance = 0.03
  controls.maxDistance = 10000
  controls.listenToKeyEvents(renderer.domElement)
  const tracks = new Map()
  const geometries = new Set()
  let visualGeometries = new Map()
  let model = null
  let disposed = false
  let pendingRender = 0
  let generation = 0
  let loadController = null
  let autoFit = true
  let contextLost = false

  function status(state, message, extra = {}) {
    if (!disposed) onStatus({ state, message, ...extra })
  }

  function scheduleRender() {
    if (disposed || contextLost || pendingRender) return
    pendingRender = window.requestAnimationFrame(() => {
      pendingRender = 0
      if (disposed || contextLost) return
      if (autoFit && Array.from(tracks.values()).some((track) => track.frame && track.visible)) {
        fitCamera()
        autoFit = false
      }
      renderer.render(scene, camera)
    })
  }

  function resize() {
    if (disposed) return
    const width = Math.max(1, Math.floor(mount.clientWidth))
    const height = Math.max(1, Math.floor(mount.clientHeight))
    renderer.setSize(width, height, false)
    camera.aspect = width / height
    camera.updateProjectionMatrix()
    scheduleRender()
  }

  function setTheme(isDark) {
    dark = isDark
    scene.background.set(dark ? 0x080b0d : 0xf7f9f7)
    scene.remove(grid)
    grid.geometry.dispose()
    disposeMaterials(grid.material)
    grid = new THREE.GridHelper(20, 40, dark ? 0x283331 : 0xc9d4cd, dark ? 0x18211f : 0xe3e9e5)
    grid.position.y = -0.002
    scene.add(grid)
    for (const track of tracks.values()) for (const { material, floor, originalColor } of track.renderMaterials) {
      if (floor) material.color.copy(dark ? new THREE.Color(0x101715) : originalColor)
    }
    scheduleRender()
  }
  const onThemeChange = event => setTheme(event.detail.theme === 'dark')
  if (followTheme) {
    window.addEventListener('moonrobo:theme-change', onThemeChange)
    setTheme(dark)
  }

  function clearTracks() {
    for (const track of tracks.values()) {
      world.remove(track.group)
      for (const material of track.materials) material.dispose()
      track.skeleton.geometry.dispose()
    }
    tracks.clear()
    autoFit = true
    scheduleRender()
  }

  function clear() {
    generation += 1
    loadController?.abort()
    loadController = null
    clearTracks()
    for (const geometry of geometries) geometry.dispose()
    geometries.clear()
    visualGeometries = new Map()
    model = null
    scheduleRender()
  }

  function createTrack(trackId, kind) {
    if (tracks.size >= POSE_REPLAY_LIMITS.tracksPerClip) throw new Error('Replay viewer track budget exceeded')
    const group = new THREE.Group()
    group.visible = false
    world.add(group)
    const bodies = new Map()
    for (const body of model.bodies) {
      const object = new THREE.Group()
      group.add(object)
      bodies.set(body.id, object)
    }
    const materials = new Set()
    const renderMaterials = []
    const modelById = new Map(model.bodies.map((body) => [body.id, body]))
    for (const visual of model.visuals) {
      // The world environment belongs to the physics pass. Duplicating an
      // opaque floor in the reference overlay obscures robot comparisons.
      if (kind === 'reference' && modelById.get(visual.body_id).parent_id === null) continue
      const sources = visualGeometries.get(visual.id)
      if (!sources) continue
      const local = new THREE.Group()
      applyPose(local, visual.local_position, visual.local_quaternion_wxyz)
      if (visual.geometry.kind === 'mesh') local.scale.set(...visual.geometry.scale)
      bodies.get(visual.body_id).add(local)
      const environment = modelById.get(visual.body_id).parent_id === null
      const color = new THREE.Color().setRGB(...visual.rgba.slice(0, 3)).lerp(new THREE.Color(TRACK_COLORS[kind]), kind === 'reference' ? 1 : environment ? 0 : 0.2)
      // Adapt only the display floor to the workbench canvas. Recorded robot
      // materials, body poses and collision geometry are unchanged.
      const floor = environment && visual.geometry.kind === 'plane'
      const originalColor = color.clone()
      if (dark && floor) color.set(0x101715)
      const baseOpacity = visual.rgba[3] * (kind === 'reference' ? 0.22 : 1)
      const material = new THREE.MeshStandardMaterial({
        color,
        metalness: 0.12,
        roughness: 0.7,
        transparent: true,
        opacity: baseOpacity,
        depthWrite: kind !== 'reference' && baseOpacity >= 0.99,
        wireframe: kind === 'reference',
        side: THREE.DoubleSide,
        polygonOffset: kind === 'reference' || floor,
        polygonOffsetFactor: floor ? 1 : -1,
        polygonOffsetUnits: floor ? 1 : -1,
      })
      materials.add(material)
      renderMaterials.push({ material, baseOpacity, floor, originalColor })
      for (const geometry of sources) {
        const mesh = new THREE.Mesh(geometry, material)
        mesh.renderOrder = kind === 'reference' ? 2 : 1
        local.add(mesh)
      }
    }
    const edges = model.bodies.filter((body) => body.parent_id !== null && modelById.get(body.parent_id)?.parent_id !== null)
    const skeletonGeometry = new THREE.BufferGeometry()
    skeletonGeometry.setAttribute('position', new THREE.BufferAttribute(new Float32Array(edges.length * 6), 3))
    const skeletonMaterial = new THREE.LineBasicMaterial({ color: TRACK_COLORS[kind], transparent: true, opacity: kind === 'reference' ? 0.7 : 0.45, depthTest: true })
    materials.add(skeletonMaterial)
    const skeleton = new THREE.LineSegments(skeletonGeometry, skeletonMaterial)
    skeleton.frustumCulled = false
    group.add(skeleton)
    const track = { group, bodies, materials, renderMaterials, skeleton, edges, kind, frame: null, visible: true, ended: false }
    tracks.set(trackId, track)
    return track
  }

  function setFrame(trackId, sourceFrame, { kind = 'physics', visible = true, ended = false } = {}) {
    if (disposed) return
    if (!model) throw new Error('Load a replay model before setting a frame')
    if (typeof trackId !== 'string' || !trackId.length || trackId.length > 128) throw new Error('Invalid replay track ID')
    if (kind !== 'physics' && kind !== 'reference') throw new Error('Invalid replay track kind')
    let track = tracks.get(trackId)
    if (track && track.kind !== kind) throw new Error('A replay track cannot change kind without clearing tracks')
    if (!track) track = createTrack(trackId, kind)
    track.visible = Boolean(visible)
    track.ended = Boolean(ended)
    if (!sourceFrame) {
      track.group.visible = false
      track.frame = null
      scheduleRender()
      return
    }
    const frame = validatePoseFrame(sourceFrame, model)
    track.frame = frame
    track.group.visible = track.visible
    for (const pose of frame.bodies) applyPose(track.bodies.get(pose.body_id), pose.position, pose.quaternion_wxyz)
    const poses = new Map(frame.bodies.map((pose) => [pose.body_id, pose]))
    const positions = track.skeleton.geometry.getAttribute('position')
    track.edges.forEach((body, index) => {
      positions.setXYZ(index * 2, ...poses.get(body.parent_id).position)
      positions.setXYZ(index * 2 + 1, ...poses.get(body.id).position)
    })
    positions.needsUpdate = true
    for (const { material, baseOpacity } of track.renderMaterials) {
      material.opacity = baseOpacity * (ended ? 0.38 : 1)
      material.depthWrite = kind === 'physics' && !ended && baseOpacity >= 0.99
    }
    track.skeleton.material.opacity = ended ? 0.25 : kind === 'reference' ? 0.7 : 0.45
    scheduleRender()
  }

  function setTrackVisibility(trackId, visible) {
    const track = tracks.get(trackId)
    if (!track || disposed) return
    track.visible = Boolean(visible)
    track.group.visible = track.visible && track.frame !== null
    scheduleRender()
  }

  function fitCamera() {
    if (disposed || !model) return
    const bounds = new THREE.Box3()
    world.updateMatrixWorld(true)
    for (const track of tracks.values()) {
      if (!track.visible || !track.frame) continue
      for (const body of model.bodies) {
        if (body.parent_id === null) continue // World/floor must not dwarf the robot.
        const object = track.bodies.get(body.id)
        const point = new THREE.Vector3().setFromMatrixPosition(object.matrixWorld)
        bounds.expandByPoint(point)
        object.traverse((child) => {
          if (child.isMesh) bounds.union(new THREE.Box3().setFromObject(child))
        })
      }
    }
    if (bounds.isEmpty()) return
    const center = bounds.getCenter(new THREE.Vector3())
    const size = bounds.getSize(new THREE.Vector3())
    const radius = Math.max(0.25, size.length() / 2)
    const vertical = camera.fov * Math.PI / 180
    const horizontal = 2 * Math.atan(Math.tan(vertical / 2) * camera.aspect)
    const distance = 1.25 * radius / Math.sin(Math.min(vertical, horizontal) / 2)
    const direction = camera.position.clone().sub(controls.target).normalize()
    if (direction.lengthSq() < 0.5) direction.set(1, 0.6, 1).normalize()
    controls.target.copy(center)
    camera.position.copy(center).addScaledVector(direction, distance)
    camera.near = Math.max(0.001, distance / 10000)
    camera.far = Math.max(1000, distance * 100)
    controls.maxDistance = Math.max(10000, distance * 10)
    camera.updateProjectionMatrix()
    controls.update()
    scheduleRender()
  }

  async function setModel(sourceModel) {
    if (disposed) throw new Error('Replay viewer is disposed')
    const nextModel = validatePoseModel(sourceModel)
    clear()
    model = nextModel
    const ownGeneration = generation
    const controller = new AbortController()
    loadController = controller
    const budget = { bytes: 0 }
    const promises = new Map()
    const loaded = new Map()
    const failures = []
    status('loading', 'Loading the recorded robot model…')
    function assertCurrent() {
      if (disposed || generation !== ownGeneration || controller.signal.aborted) throw aborted()
    }
    async function loadGeometry(visual) {
      const shape = visual.geometry
      const cacheKey = shape.kind === 'mesh' ? shape.sha256 : JSON.stringify(shape)
      if (!promises.has(cacheKey)) {
        promises.set(cacheKey, (async () => {
          let result
          if (shape.kind !== 'mesh') result = [primitiveGeometry(shape)]
          else {
            const resolved = await resolveAssetUrl(shape, visual, nextModel, { signal: controller.signal })
            assertCurrent()
            const url = new URL(resolved, window.location.href)
            if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || !approvedOrigins.has(url.origin)) {
              throw new Error('Replay mesh resolver returned an unapproved asset origin')
            }
            const response = await fetch(url.href, { signal: controller.signal, cache: 'no-store', redirect: 'error' })
            if (!response.ok) throw new Error(`Replay mesh fetch failed (${response.status})`)
            const bytes = await readBoundedAsset(response, budget, controller.signal)
            assertCurrent()
            if (!globalThis.crypto?.subtle) throw new Error('Mesh integrity validation requires a secure browser context')
            const digest = await crypto.subtle.digest('SHA-256', bytes)
            const hash = Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('')
            assertCurrent()
            if (hash !== shape.sha256) throw new Error('Replay mesh SHA-256 does not match its model')
            result = parseMesh(bytes, shape.asset)
          }
          try { assertCurrent() } catch (error) {
            for (const geometry of result) geometry.dispose()
            throw error
          }
          for (const geometry of result) geometries.add(geometry)
          return result
        })())
      }
      return await promises.get(cacheKey)
    }
    let nextIndex = 0
    async function worker() {
      while (nextIndex < nextModel.visuals.length) {
        assertCurrent()
        const visual = nextModel.visuals[nextIndex++]
        try { loaded.set(visual.id, await loadGeometry(visual)) }
        catch (error) {
          assertCurrent()
          failures.push({ visualId: visual.id, message: String(error?.message || error) })
        }
      }
    }
    await Promise.all(Array.from({ length: Math.min(4, nextModel.visuals.length) }, worker))
    assertCurrent()
    visualGeometries = loaded
    // Live callers may push poses while geometry is loading. Rebuild their
    // materials/visuals and restore the latest accepted pose atomically.
    const latest = Array.from(tracks, ([id, track]) => ({ id, ...track }))
    clearTracks()
    for (const track of latest) {
      setFrame(track.id, track.frame, { kind: track.kind, visible: track.visible, ended: track.ended })
    }
    status(failures.length ? 'partial' : 'ready', failures.length ? `Model loaded with ${failures.length} missing geometries. The skeleton shows recorded body poses only.` : 'Recorded robot model loaded.', { failedMeshes: failures.length, failures })
    scheduleRender()
    return nextModel
  }

  const onContextLost = (event) => {
    if (disposed) return
    event.preventDefault()
    contextLost = true
    status('error', 'The 3D graphics context was lost. Reopen the recording to restore it.')
  }
  const onContextRestored = () => {
    if (disposed) return
    contextLost = false
    status('ready', 'The 3D graphics context has been restored.')
    scheduleRender()
  }
  controls.addEventListener('change', scheduleRender)
  renderer.domElement.addEventListener('webglcontextlost', onContextLost)
  renderer.domElement.addEventListener('webglcontextrestored', onContextRestored)
  const observer = typeof ResizeObserver === 'function' ? new ResizeObserver(resize) : null
  if (observer) observer.observe(mount)
  else window.addEventListener('resize', resize)
  resize()
  controls.update()

  return Object.freeze({
    setModel,
    setFrame,
    setTrackVisibility,
    clearTracks,
    clear,
    fitCamera,
    setTheme,
    dispose() {
      if (disposed) return
      clear()
      disposed = true
      if (pendingRender) window.cancelAnimationFrame(pendingRender)
      pendingRender = 0
      observer?.disconnect()
      window.removeEventListener('resize', resize)
      window.removeEventListener('moonrobo:theme-change', onThemeChange)
      controls.removeEventListener('change', scheduleRender)
      controls.dispose()
      renderer.domElement.removeEventListener('webglcontextlost', onContextLost)
      renderer.domElement.removeEventListener('webglcontextrestored', onContextRestored)
      grid.geometry.dispose()
      disposeMaterials(grid.material)
      renderer.dispose()
      renderer.forceContextLoss()
      renderer.domElement.remove()
    },
  })
}

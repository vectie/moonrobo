import * as THREE from 'three'
import { STLLoader } from 'three/examples/jsm/loaders/STLLoader.js'

const loader = new STLLoader()
const geometryCache = new Map()
const pendingLoads = new Map()

function finiteAttributeArray(attribute, itemSize) {
  if (!attribute?.array) return null
  const source = attribute.array
  const clean = []
  const stride = itemSize * 3
  let removed = 0

  for (let index = 0; index + stride - 1 < source.length; index += stride) {
    let valid = true
    for (let offset = 0; offset < stride; offset += 1) {
      const value = source[index + offset]
      if (!Number.isFinite(value)) {
        valid = false
        break
      }
    }
    if (valid) {
      for (let offset = 0; offset < stride; offset += 1) clean.push(source[index + offset])
    } else {
      removed += 1
    }
  }

  return { array: new Float32Array(clean), removed }
}

function sanitizeStlGeometry(geometry) {
  const position = finiteAttributeArray(geometry.getAttribute('position'), 3)
  if (!position || position.array.length === 0) {
    geometry.dispose()
    throw new Error('STL contains no finite triangles')
  }

  const normal = finiteAttributeArray(geometry.getAttribute('normal'), 3)
  const sanitized = new THREE.BufferGeometry()
  sanitized.setAttribute('position', new THREE.Float32BufferAttribute(position.array, 3))
  if (normal && normal.array.length === position.array.length) {
    sanitized.setAttribute('normal', new THREE.Float32BufferAttribute(normal.array, 3))
  } else {
    sanitized.computeVertexNormals()
  }
  sanitized.computeBoundingBox()
  sanitized.computeBoundingSphere()
  geometry.dispose()
  return {
    geometry: sanitized,
    removedTriangles: position.removed,
  }
}

async function fetchStlArrayBuffer(url) {
  const response = await fetch(url, { cache: 'no-store' })
  if (!response.ok) {
    throw new Error(`STL fetch failed ${response.status}`)
  }
  return await response.arrayBuffer()
}

async function loadStlGeometryData(url) {
  if (geometryCache.has(url)) return geometryCache.get(url)
  if (pendingLoads.has(url)) return await pendingLoads.get(url)

  const pending = fetchStlArrayBuffer(url)
    .then((arrayBuffer) => sanitizeStlGeometry(loader.parse(arrayBuffer)))
    .then((data) => {
      geometryCache.set(url, data)
      return data
    })
    .finally(() => {
      pendingLoads.delete(url)
    })
  pendingLoads.set(url, pending)
  return await pending
}

export async function loadStlGeometry(url) {
  const data = await loadStlGeometryData(url)
  const geometry = data.geometry.clone()
  geometry.computeBoundingBox()
  geometry.computeBoundingSphere()
  return {
    geometry,
    removedTriangles: data.removedTriangles,
  }
}

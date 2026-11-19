import * as T from "three";
import { OrbitControls } from "three/examples/jsm/controls/OrbitControls.js";

export const assetURL = (file) => new URL(`./e1/assets/${file}`, document.baseURI).href;
export async function loadFile(file, type = "json") {
  const response = await fetch(assetURL(file));
  if (!response.ok) throw Error(`资源载入失败 (${response.status})`);
  return response[type]();
}
export async function verify(buffer, expected) {
  const digest = [...new Uint8Array(await crypto.subtle.digest("SHA-256", buffer))]
    .map((v) => v.toString(16).padStart(2, "0")).join("");
  if (digest !== expected) throw Error("E1 资源完整性校验失败");
}
export function decodeMesh(buffer) {
  if (buffer.byteLength < 8) throw Error("无效模型文件");
  const header = new DataView(buffer), vertices = header.getUint32(0, true), indices = header.getUint32(4, true);
  if (vertices < 3 || indices % 3 || 8 + vertices * 12 + indices * 4 !== buffer.byteLength)
    throw Error("无效模型布局");
  const geometry = new T.BufferGeometry();
  const positions = new Float32Array(buffer, 8, vertices * 3), faces = new Uint32Array(buffer, 8 + vertices * 12, indices);
  if (positions.some((v) => !Number.isFinite(v)) || faces.some((v) => v >= vertices)) throw Error("无效模型坐标");
  geometry.setAttribute("position", new T.BufferAttribute(positions, 3));
  geometry.setIndex(new T.BufferAttribute(faces, 1));
  geometry.computeVertexNormals();
  return geometry;
}
export async function loadAssets() {
  const manifest = await loadFile("manifest.json");
  if (manifest.format !== "moonrobo.e1-showcase.v1" || manifest.robot.joints.length !== 23)
    throw Error("E1 模型版本不匹配");
  return loadReplayAssets(manifest, loadFile);
}
export async function loadReplayAssets(manifest, readFile) {
  const xmlBytes = await readFile("scene.xml", "arrayBuffer");
  await verify(xmlBytes, manifest.scene_sha256);
  const xml = new DOMParser().parseFromString(new TextDecoder().decode(xmlBytes), "application/xml");
  if (xml.querySelector("parsererror")) throw Error("E1 模型结构无法读取");
  const geometries = new Map();
  await Promise.all(Object.entries(manifest.meshes).map(async ([key, item]) => {
    const bytes = await readFile(item.file, "arrayBuffer");
    await verify(bytes, item.sha256);
    geometries.set(key, decodeMesh(bytes));
  }));
  return { manifest, xml, geometries };
}
const numbers = (node, attr, fallback) => node.hasAttribute(attr)
  ? node.getAttribute(attr).trim().split(/\s+/).map(Number) : fallback;
const children = (node, tag) => [...node.children].filter((n) => n.tagName === tag);
function transform(group, node) {
  group.position.fromArray(numbers(node, "pos", [0, 0, 0]));
  const q = numbers(node, "quat", [1, 0, 0, 0]);
  group.quaternion.set(q[1], q[2], q[3], q[0]).normalize();
  if (node.hasAttribute("euler")) throw Error("模型存在未支持的旋转表示");
}
export class E1Viewer {
  constructor(canvas, assets, { hero = false, visualGroup = null } = {}) {
    this.visualGroup = visualGroup;
    this.canvas = canvas;
    this.hero = hero;
    this.visible = true;
    this.assets = assets;
    this.joints = new Map();
    this.renderer = new T.WebGLRenderer({ canvas, antialias: true, alpha: hero });
    this.renderer.setPixelRatio(Math.min(devicePixelRatio, 1.7));
    this.renderer.shadowMap.enabled = true;
    this.renderer.shadowMap.type = T.PCFSoftShadowMap;
    this.renderer.setClearColor(hero ? 0xffffff : 0xf6f7f8, hero ? 0 : 1);
    this.scene = new T.Scene();
    this.camera = new T.PerspectiveCamera(32, 1, .02, 40);
    this.camera.up.set(0, 0, 1);
    this.controls = new OrbitControls(this.camera, canvas);
    this.controls.enablePan = false;
    this.controls.minDistance = 1.3;
    this.controls.maxDistance = 7;
    this.controls.maxPolarAngle = Math.PI * .49;
    this.controls.autoRotateSpeed = .65;
    this.controls.addEventListener("change", () => this.render());
    this.canvas.addEventListener("keydown", (event) => {
      if (!["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"].includes(event.key)) return;
      event.preventDefault();
      const offset = this.camera.position.clone().sub(this.controls.target), spherical = new T.Spherical().setFromVector3(new T.Vector3(offset.x, offset.z, -offset.y));
      if (event.key === "ArrowLeft") spherical.theta -= .12;
      if (event.key === "ArrowRight") spherical.theta += .12;
      if (event.key === "ArrowUp") spherical.radius = Math.max(1.3, spherical.radius * .9);
      if (event.key === "ArrowDown") spherical.radius = Math.min(7, spherical.radius * 1.1);
      const v = new T.Vector3().setFromSpherical(spherical);
      this.camera.position.set(v.x, -v.z, v.y).add(this.controls.target);
      this.controls.update();
      this.render();
    });
    const sky = new T.HemisphereLight(0xffffff, 0xa0a69b, 2.7);
    sky.up.set(0, 0, 1);
    this.scene.add(sky);
    const key = new T.DirectionalLight(0xfff8ee, 3.4);
    key.position.set(2, -3, 5);
    key.castShadow = true;
    key.shadow.mapSize.set(1024, 1024);
    Object.assign(key.shadow.camera, { left: -2, right: 2, top: 2, bottom: -2, near: .1, far: 12 });
    key.shadow.normalBias = .006;
    this.scene.add(key);
    const fill = new T.DirectionalLight(0xd8ebff, 1.8);
    fill.position.set(-2, 2, 2);
    this.scene.add(fill);
    const floor = new T.Mesh(new T.PlaneGeometry(100, 100), new T.ShadowMaterial({ opacity: .13 }));
    floor.position.z = -.003;
    floor.receiveShadow = true;
    this.scene.add(floor);
    if (!hero) {
      const grid = new T.GridHelper(6, 24, 0xd3d7d9, 0xe0e3e5);
      grid.rotation.x = Math.PI / 2;
      grid.position.z = -.004;
      grid.material.transparent = true;
      grid.material.opacity = .45;
      this.scene.add(grid);
      this.scene.fog = new T.Fog(0xf6f7f8, 4, 9);
    }
    this.root = this.body(children(assets.xml.querySelector("worldbody"), "body")[0]);
    this.scene.add(this.root);
    this.anchor = [0, 0];
    this.pose([0, 0, .85, 0, 0, 0, 1, ...assets.manifest.robot.default_q]);
    // Place the neutral studio pose on its display floor. Reference playback
    // retains the original root height and is never shifted vertically.
    if (hero) this.root.position.z -= new T.Box3().setFromObject(this.root).min.z;
    this.setView("perspective");
    this.observer = new ResizeObserver(() => this.render());
    this.observer.observe(canvas);
    this.visibility = new IntersectionObserver(([entry]) => { this.visible = entry.isIntersecting; if (this.visible) this.render(); });
    this.visibility.observe(canvas);
    this.render();
  }
  body(node) {
    const group = new T.Group();
    transform(group, node);
    let parent = group;
    for (const joint of children(node, "joint")) {
      const name = joint.getAttribute("name"), pivot = new T.Group(), undo = new T.Group();
      const pos = numbers(joint, "pos", [0, 0, 0]), axis = new T.Vector3().fromArray(numbers(joint, "axis", [0, 0, 1])).normalize();
      pivot.position.fromArray(pos);
      undo.position.fromArray(pos).multiplyScalar(-1);
      parent.add(pivot);
      pivot.add(undo);
      parent = undo;
      this.joints.set(name, { pivot, axis });
    }
    for (const geom of children(node, "geom")) {
      if (this.visualGroup !== null && geom.getAttribute("group") !== this.visualGroup) continue;
      let geometry;
      if (geom.getAttribute("type") === "mesh") {
        const name = geom.getAttribute("mesh");
        const asset = [...this.assets.xml.querySelectorAll("asset > mesh")].find((m) => m.getAttribute("name") === name);
        geometry = this.assets.geometries.get(asset?.getAttribute("file").split("/").at(-1));
        if (!geometry) throw Error("缺少 E1 网格：" + name);
      } else if (geom.getAttribute("type") === "box") {
        const size = numbers(geom, "size", [0, 0, 0]);
        geometry = new T.BoxGeometry(...size.map((v) => v * 2));
      } else continue;
      const rgba = numbers(geom, "rgba", [.7, .72, .73, 1]);
      const material = new T.MeshStandardMaterial({ color: new T.Color(...rgba.slice(0, 3)), metalness: .3, roughness: .44 });
      const mesh = new T.Mesh(geometry, material);
      transform(mesh, geom);
      mesh.castShadow = true;
      mesh.receiveShadow = true;
      parent.add(mesh);
    }
    for (const child of children(node, "body")) parent.add(this.body(child));
    return group;
  }
  pose(row) {
    this.root.position.set(row[0] - this.anchor[0], row[1] - this.anchor[1], row[2]);
    this.root.quaternion.set(row[3], row[4], row[5], row[6]).normalize();
    this.assets.manifest.robot.joints.forEach((name, i) => {
      const joint = this.joints.get(name);
      if (!joint) throw Error("缺少 E1 关节：" + name);
      joint.pivot.quaternion.setFromAxisAngle(joint.axis, row[7 + i]);
    });
  }
  setView(view) {
    this.controls.target.set(0, 0, .62);
    this.camera.position.set(...(view === "front" ? [3.05, 0, .95] : view === "side" ? [0, -3.05, .95] : [2.05, -3.15, 1.28]));
    this.controls.update();
    this.render();
  }
  render() {
    if (!this.visible || document.hidden) return;
    const width = this.canvas.clientWidth, height = this.canvas.clientHeight;
    if (!width || !height) return;
    if (width !== this.width || height !== this.height) {
      this.width = width; this.height = height;
      this.renderer.setSize(width, height, false);
      this.camera.aspect = width / height;
      this.camera.updateProjectionMatrix();
    }
    this.renderer.render(this.scene, this.camera);
  }
}

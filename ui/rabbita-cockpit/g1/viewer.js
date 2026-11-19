import * as T from "three";
import { OrbitControls } from "three/examples/jsm/controls/OrbitControls.js";
const rot = new T.Matrix4();
// Both overlays keep their physical world positions. A depth-only pass per
// ghost prevents the rear panels from showing through its front surface.
const goalGhost = { color: 0x8e8e93, opacity: 0.38, order: 2 };
const worldGhost = { color: 0x5da1e5, opacity: 0.55, order: 4 };
export class Viewer {
  constructor(canvas, model, onPush, { studio = false, lane = "all" } = {}) {
    this.lane = lane;
    this.overlay = { goal: false, physics: false };
    this.studio = studio;
    this.renderer = new T.WebGLRenderer({
      canvas,
      antialias: true,
      alpha: false,
      preserveDrawingBuffer: true,
    });
    this.renderer.setPixelRatio(Math.min(devicePixelRatio, 1.8));
    this.renderer.shadowMap.enabled = true;
    this.renderer.shadowMap.type = T.PCFSoftShadowMap;
    this.scene = new T.Scene();
    this.scene.background = new T.Color(studio ? 0xffffff : 0xf7f7fa);
    this.scene.fog = new T.FogExp2(this.scene.background, 0.075);
    this.camera = new T.PerspectiveCamera(32, 1, 0.03, 80);
    this.camera.up.set(0, 0, 1);
    this.camera.position.set(
      ...(studio ? [1.85, -3.35, 1.26] : [3.45, -2.05, 1.55]),
    );
    this.controls = new OrbitControls(this.camera, canvas);
    this.controls.target.set(0, 0, studio ? 0.64 : 0.77);
    this.controls.maxPolarAngle = Math.PI * 0.48;
    this.controls.minDistance = 1.35;
    this.controls.maxDistance = 12;
    const sky = new T.HemisphereLight(
      0xffffff,
      studio ? 0x96917e : 0x929296,
      studio ? 2.5 : 1.9,
    );
    sky.up.set(0, 0, 1);
    sky.position.set(0, 0, 4);
    this.scene.add(sky);
    this.key = new T.DirectionalLight(0xffffff, 3.15);
    this.key.position.set(3, -4, 7);
    this.key.castShadow = true;
    this.key.shadow.mapSize.set(2048, 2048);
    this.key.shadow.camera.left = -5;
    this.key.shadow.camera.right = 5;
    this.key.shadow.camera.top = 5;
    this.key.shadow.camera.bottom = -5;
    this.key.shadow.normalBias = 0.018;
    this.scene.add(this.key, this.key.target);
    const floor = new T.Mesh(
      new T.PlaneGeometry(140, 140),
      new T.ShadowMaterial({ opacity: studio ? 0.12 : 0.14 }),
    );
    floor.receiveShadow = true;
    floor.position.z = -0.006;
    this.scene.add(floor);
    const grid = new T.GridHelper(100, 100, 0xb9b9bf, 0xb9b9bf);
    grid.rotation.x = Math.PI / 2;
    grid.material.transparent = true;
    grid.material.opacity = 0.22;
    grid.visible = !studio;
    grid.position.z = -0.003;
    this.scene.add(grid);
    // Screen-space antialiasing keeps the close grid legible; it dissolves
    // around the robot rather than extending as fine lines to the horizon.
    if (!studio) {
      grid.visible = false;
      this.floorGrid = new T.Mesh(
        new T.PlaneGeometry(100, 100),
        new T.ShaderMaterial({
          transparent: true,
          depthWrite: false,
          uniforms: { center: { value: new T.Vector2() }, angle: { value: 0 } },
          vertexShader:
            "varying vec2 floorXY; void main(){vec4 w=modelMatrix*vec4(position,1.);floorXY=w.xy;gl_Position=projectionMatrix*viewMatrix*w;}",
          fragmentShader: `varying vec2 floorXY; uniform vec2 center; uniform float angle;
        void main(){float c=cos(angle),s=sin(angle);vec2 uv=mat2(c,-s,s,c)*floorXY;
        vec2 d=abs(fract(uv+.5)-.5)/max(fwidth(uv),vec2(.0001));
        float line=1.-smoothstep(.25,1.4,min(d.x,d.y));
        gl_FragColor=vec4(.58,.58,.61,.35*line*(1.-smoothstep(.6,3.8,distance(floorXY,center))));}`,
        }),
      );
      this.floorGrid.position.z = -0.002;
      this.scene.add(this.floorGrid);
      const textureCanvas = document.createElement("canvas");
      textureCanvas.width = textureCanvas.height = 128;
      const ctx = textureCanvas.getContext("2d"),
        fade = ctx.createRadialGradient(64, 64, 0, 64, 64, 64);
      fade.addColorStop(0, "rgba(0,0,0,.21)");
      fade.addColorStop(0.4, "rgba(0,0,0,.11)");
      fade.addColorStop(1, "rgba(0,0,0,0)");
      ctx.fillStyle = fade;
      ctx.fillRect(0, 0, 128, 128);
      this.contact = new T.Mesh(
        new T.PlaneGeometry(1.15, 0.91),
        new T.MeshBasicMaterial({
          map: new T.CanvasTexture(textureCanvas),
          transparent: true,
          depthWrite: false,
        }),
      );
      this.scene.add(this.contact);
      floor.material.opacity = 0.045;
    }
    this.robots = [];
    this.geometries = [floor.geometry, grid.geometry];
    this.materials = [floor.material, grid.material];
    const ghostDepth = new T.MeshBasicMaterial({
      colorWrite: false,
      depthWrite: true,
      transparent: true,
    });
    this.materials.push(ghostDepth);
    const cache = new Map();
    for (let lane = 0; lane < 3; lane++) {
      const group = new T.Group(),
        items = [];
      // Offsets are only for the renderer. All three trajectories are in the same physical frame.
      this.scene.add(group);
      this.robots.push({ group, items });
      for (let g = 0; g < model.ngeom; g++) {
        const id = model.geom_dataid[g];
        if (model.geom_type[g] !== 7 || id < 0 || model.geom_group[g] !== 1)
          continue;
        if (!cache.has(id)) {
          const geo = new T.BufferGeometry(),
            v = model.mesh_vertadr[id],
            n = model.mesh_vertnum[id],
            fi = model.mesh_faceadr[id],
            fn = model.mesh_facenum[id];
          geo.setAttribute(
            "position",
            new T.Float32BufferAttribute(
              model.mesh_vert.slice(3 * v, 3 * (v + n)),
              3,
            ),
          );
          geo.setIndex(
            new T.Uint32BufferAttribute(
              new Uint32Array(model.mesh_face.slice(3 * fi, 3 * (fi + fn))),
              1,
            ),
          );
          geo.computeVertexNormals();
          cache.set(id, geo);
          this.geometries.push(geo);
        }
        const shade = model.geom_rgba[4 * g],
          dark = shade < 0.32;
        const color =
          lane === 1
            ? dark
              ? 0x292d31
              : 0xe3e5de
            : lane === 0
              ? dark
                ? 0x184d49
                : 0x74a69a
              : dark
                ? 0x8e4a33
                : 0xde9877;
        const material = new T.MeshStandardMaterial({
          color,
          metalness: 0.23,
          roughness: 0.44,
        });
        this.materials.push(material);
        const mesh = new T.Mesh(cache.get(id), material);
        mesh.castShadow = true;
        mesh.receiveShadow = true;
        let depth;
        if (!studio && lane !== 1) {
          depth = new T.Mesh(mesh.geometry, ghostDepth);
          depth.visible = false;
          mesh.add(depth);
        }
        group.add(mesh);
        items.push({
          g,
          mesh,
          depth,
          color,
          soloColor: dark ? 0x292d31 : 0xe3e5de,
        });
      }
    }
    this.pointer = null;
    const ray = new T.Raycaster();
    this.down = (e) => {
      if (e.button !== 0) return;
      const b = canvas.getBoundingClientRect();
      ray.setFromCamera(
        new T.Vector2(
          ((e.clientX - b.x) / b.width) * 2 - 1,
          1 - ((e.clientY - b.y) / b.height) * 2,
        ),
        this.camera,
      );
      if (
        this.robots.some(
          (r) =>
            r.group.visible &&
            ray.intersectObjects(r.group.children, false).length,
        )
      ) {
        this.pointer = [e.clientX, e.clientY];
        this.controls.enabled = false;
        canvas.setPointerCapture(e.pointerId);
      }
    };
    this.up = (e) => {
      if (!this.pointer) return;
      const dx = e.clientX - this.pointer[0],
        dy = e.clientY - this.pointer[1];
      this.pointer = null;
      this.controls.enabled = true;
      if (Math.hypot(dx, dy) > 4) {
        const right = new T.Vector3().setFromMatrixColumn(
          this.camera.matrixWorld,
          0,
        );
        const fwd = new T.Vector3();
        this.camera.getWorldDirection(fwd);
        fwd.z = 0;
        fwd.normalize();
        right.multiplyScalar(dx).addScaledVector(fwd, -dy).normalize();
        onPush(right.x, right.y);
      }
    };
    canvas.addEventListener("pointerdown", this.down, true);
    canvas.addEventListener("pointerup", this.up);
    this.cancel = () => {
      this.pointer = null;
      this.controls.enabled = true;
    };
    canvas.addEventListener("pointercancel", this.cancel);
    this.resize = new ResizeObserver(() => this.render());
    this.resize.observe(canvas);
    this.canvas = canvas;
  }
  frameClip(sim) {
    if (this.studio) return;
    const r = sim.clip[0].r,
      a = Math.atan2(r[3], r[0]) + 1.06;
    this.controls.target.set(0, 0, 0.45);
    this.camera.position.set(4.05 * Math.cos(a), 4.05 * Math.sin(a), 2.18);
    this.floorGrid.material.uniforms.angle.value = a - Math.PI / 4;
    this.focus = [0, 0];
    this.controls.update();
  }
  update(sim) {
    const origin = sim.clip[0].p;
    const p = sim.data.qpos,
      focus = [p[0] - origin[0], p[1] - origin[1]];
    const before = this.focus || [0, 0];
    this.camera.position.x += focus[0] - before[0];
    this.camera.position.y += focus[1] - before[1];
    this.controls.target.x += focus[0] - before[0];
    this.controls.target.y += focus[1] - before[1];
    this.focus = focus;
    if (this.floorGrid) {
      this.floorGrid.material.uniforms.center.value.set(...focus);
      this.floorGrid.position.set(...focus, -0.002);
      this.contact.position.set(...focus, -0.001);
      this.contact.visible = this.lane !== "all";
    }
    for (const [lane, data] of [sim.refData, sim.data, sim.wmData].entries()) {
      const robot = this.robots[lane];
      const split = this.lane === "all";
      const showGoal = this.overlay.goal && lane === 0;
      const showPhysics =
        this.lane === "world" && this.overlay.physics && lane === 1;
      robot.group.visible =
        (lane !== 2 || sim.prediction) &&
        (split ||
          this.lane === ["goal", "physics", "world"][lane] ||
          showGoal ||
          showPhysics);
      if (!robot.group.visible) continue;
      let ghost = null;
      if (!split && this.lane !== "goal") {
        if (lane === 0) ghost = goalGhost;
        if (lane === 2 && this.overlay.physics) ghost = worldGhost;
      }
      const offset = split ? (lane - 1) * 1.18 : 0,
        basis = this.camera.matrixWorld.elements;
      robot.group.position.set(
        -origin[0] + offset * basis[0],
        -origin[1] + offset * basis[1],
        0,
      );
      const x = data.geom_xpos,
        r = data.geom_xmat;
      if (robot.ghost !== ghost || robot.split !== split) {
        for (const { mesh, depth, color, soloColor } of robot.items) {
          mesh.material.color.setHex(
            ghost?.color ?? (split ? color : soloColor),
          );
          mesh.material.transparent = !!ghost;
          mesh.material.opacity = ghost?.opacity ?? 1;
          mesh.material.depthWrite = !ghost;
          mesh.castShadow = !ghost;
          mesh.renderOrder = ghost?.order ?? 0;
          if (depth) {
            depth.visible = !!ghost;
            depth.renderOrder = mesh.renderOrder - 1;
          }
        }
        robot.ghost = ghost;
        robot.split = split;
      }
      for (const { g, mesh } of robot.items) {
        let i = g * 9;
        rot.set(
          r[i],
          r[i + 1],
          r[i + 2],
          0,
          r[i + 3],
          r[i + 4],
          r[i + 5],
          0,
          r[i + 6],
          r[i + 7],
          r[i + 8],
          0,
          0,
          0,
          0,
          1,
        );
        mesh.quaternion.setFromRotationMatrix(rot);
        mesh.position.fromArray(x, g * 3);
      }
    }
    this.render();
  }
  render() {
    const c = this.renderer.domElement,
      w = c.clientWidth,
      h = c.clientHeight;
    if (!w || !h) return;
    const pixel = this.renderer.getPixelRatio();
    if (Math.abs(c.width - w * pixel) > 1 || Math.abs(c.height - h * pixel) > 1)
      this.renderer.setSize(w, h, false);
    this.camera.aspect = w / h;
    // Preserve the solo portrait framing; fit all three offset robots across
    // a narrow canvas without changing the physical states or orbit distance.
    this.camera.zoom = this.studio
      ? 1
      : 0.73 *
        (this.lane === "all" ? Math.min(1, this.camera.aspect / 1.08) : 1);
    this.camera.updateProjectionMatrix();
    this.controls.update();
    this.renderer.render(this.scene, this.camera);
  }
  dispose() {
    if (this.floorGrid) {
      this.floorGrid.geometry.dispose();
      this.floorGrid.material.dispose();
      this.contact.geometry.dispose();
      this.contact.material.map.dispose();
      this.contact.material.dispose();
    }
    this.resize.disconnect();
    this.canvas.removeEventListener("pointerdown", this.down, true);
    this.canvas.removeEventListener("pointerup", this.up);
    this.canvas.removeEventListener("pointercancel", this.cancel);
    this.controls.dispose();
    for (const g of this.geometries) g.dispose();
    for (const m of this.materials) m.dispose();
    this.key.shadow.dispose();
    this.renderer.dispose();
  }
}

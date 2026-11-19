#include <moonbit.h>
#include <string.h>
#include <stdio.h>
#include <math.h>
#include <dlfcn.h>
#if __has_include(<mujoco/mujoco.h>)
#include <mujoco/mujoco.h>
#define MOONROBO_REPLAY_HAVE_MUJOCO 1
#endif

/* This isolated model handle only reads compiled visual geometry. It never
 * allocates mjData, steps physics, or reaches inside learning_physics.Runtime. */
typedef struct {
  char error[2048];
#ifdef MOONROBO_REPLAY_HAVE_MUJOCO
  void *library;
  mjModel *model;
  void (*delete_model)(mjModel *);
#endif
} ReplayModel;

static moonbit_bytes_t replay_text(const char *text) {
  int n = (int)strlen(text);
  moonbit_bytes_t result = moonbit_make_bytes(n, 0);
  memcpy(result, text, (size_t)n);
  return result;
}

static void replay_model_cleanup(void *opaque) {
#ifdef MOONROBO_REPLAY_HAVE_MUJOCO
  ReplayModel *handle = (ReplayModel *)opaque;
  if (handle->model && handle->delete_model) handle->delete_model(handle->model);
  if (handle->library) dlclose(handle->library);
#else
  (void)opaque;
#endif
}

MOONBIT_FFI_EXPORT ReplayModel *moonrobo_replay_model_open(
    const unsigned char *library, const unsigned char *scene) {
  ReplayModel *handle = moonbit_make_external_object(replay_model_cleanup, sizeof(ReplayModel));
  memset(handle, 0, sizeof(*handle));
#ifdef MOONROBO_REPLAY_HAVE_MUJOCO
  handle->library = dlopen((const char *)library, RTLD_NOW | RTLD_LOCAL);
  if (!handle->library) {
    snprintf(handle->error, sizeof(handle->error), "%s", dlerror());
    return handle;
  }
  int (*version)(void) = NULL;
  mjModel *(*load_xml)(const char *, const mjVFS *, char *, int) = NULL;
  *(void **)(&version) = dlsym(handle->library, "mj_version");
  *(void **)(&load_xml) = dlsym(handle->library, "mj_loadXML");
  *(void **)(&handle->delete_model) = dlsym(handle->library, "mj_deleteModel");
  if (!version || !load_xml || !handle->delete_model) {
    snprintf(handle->error, sizeof(handle->error), "MuJoCo visual export requires mj_version/mj_loadXML/mj_deleteModel");
    return handle;
  }
  if (version() != mjVERSION_HEADER) {
    snprintf(handle->error, sizeof(handle->error), "MuJoCo visual ABI mismatch: header=%d runtime=%d", mjVERSION_HEADER, version());
    return handle;
  }
  handle->model = load_xml((const char *)scene, NULL, handle->error, sizeof(handle->error));
  if (!handle->model && !handle->error[0]) {
    snprintf(handle->error, sizeof(handle->error), "mj_loadXML failed for replay visual model");
  }
#else
  (void)library; (void)scene;
  snprintf(handle->error, sizeof(handle->error), "MuJoCo headers unavailable at build time; rebuild with matching include/mujoco/mujoco.h for visual export");
#endif
  return handle;
}

MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_replay_model_error(ReplayModel *handle) {
  return replay_text(handle->error);
}

MOONBIT_FFI_EXPORT int32_t moonrobo_replay_model_count(ReplayModel *handle, int32_t kind, int32_t id) {
#ifdef MOONROBO_REPLAY_HAVE_MUJOCO
  mjModel *m = handle->model;
  if (!m) return -1;
  if (kind == 0) return m->ngeom;
  if (kind == 1) return m->nbody;
  if (id < 0 || id >= m->nmesh) return -1;
  if (kind == 2) return m->mesh_vertnum[id];
  if (kind == 3) return m->mesh_facenum[id];
#else
  (void)handle; (void)kind; (void)id;
#endif
  return -1;
}

MOONBIT_FFI_EXPORT double moonrobo_replay_model_value(ReplayModel *handle, int32_t kind, int32_t id, int32_t component) {
#ifdef MOONROBO_REPLAY_HAVE_MUJOCO
  mjModel *m = handle->model;
  if (!m || component < 0) return NAN;
  if (kind == 10 || kind == 11) {
    if (id < 0 || id >= m->nmesh) return NAN;
    if (kind == 10 && component < m->mesh_vertnum[id] * 3)
      return m->mesh_vert[m->mesh_vertadr[id] * 3 + component];
    if (kind == 11 && component < m->mesh_facenum[id] * 3)
      return m->mesh_face[m->mesh_faceadr[id] * 3 + component];
    return NAN;
  }
  if (id < 0 || id >= m->ngeom) return NAN;
  switch (kind) {
    case 0: return m->geom_type[id];
    case 1: return m->geom_bodyid[id];
    case 2: return m->geom_dataid[id];
    case 3: return component < 3 ? m->geom_size[id * 3 + component] : NAN;
    case 4: return component < 3 ? m->geom_pos[id * 3 + component] : NAN;
    case 5: return component < 4 ? m->geom_quat[id * 4 + component] : NAN;
    case 6: {
      if (component >= 4) return NAN;
      const float *rgba = m->geom_rgba + id * 4;
      int mat = m->geom_matid[id];
      if (mat >= 0 && rgba[0] == .5f && rgba[1] == .5f && rgba[2] == .5f && rgba[3] == 1.f)
        return m->mat_rgba[mat * 4 + component];
      return rgba[component];
    }
    case 7: return m->geom_group[id];
  }
#else
  (void)handle; (void)kind; (void)id; (void)component;
#endif
  return NAN;
}

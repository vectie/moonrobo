///|
#cfg(target="js")
extern "js" fn register_mesh_pick_bridge(handler : (String) -> Unit) =
  #| (handler) => {
  #|   const eventName = 'moonrobo:urdf-editor-select';
  #|   const previous = globalThis.__moonroboUrdfEditorMeshPickListener;
  #|   if (typeof previous === 'function') {
  #|     globalThis.removeEventListener(eventName, previous);
  #|   }
  #|   const dispatch = (nodeId) => {
  #|     if (typeof nodeId !== 'string') return;
  #|     const trimmed = nodeId.trim();
  #|     if (trimmed.length === 0) return;
  #|     handler(trimmed);
  #|   };
  #|   const listener = (event) => dispatch(event?.detail?.nodeId);
  #|   globalThis.__moonroboUrdfEditorMeshPickListener = listener;
  #|   globalThis.__moonroboSelectUrdfEditorNode = dispatch;
  #|   globalThis.addEventListener(eventName, listener);
  #| }

///|
#cfg(target="js")
extern "js" fn notify_mesh_viewer_selection(node_id : String) =
  #| (nodeId) => {
  #|   const trimmed = typeof nodeId === 'string' ? nodeId.trim() : '';
  #|   if (trimmed.length === 0) return;
  #|   globalThis.dispatchEvent(
  #|     new CustomEvent('moonrobo:urdf-editor-selection-changed', {
  #|       detail: { nodeId: trimmed, focus: true },
  #|     }),
  #|   );
  #| }

///|
#cfg(target="js")
extern "js" fn register_transform_commit_bridge(
  handler : (String, String, String, String, String, String, String) -> Unit,
) =
  #| (handler) => {
  #|   const eventName = 'moonrobo:urdf-editor-transform-commit';
  #|   const previous = globalThis.__moonroboUrdfTransformCommitListener;
  #|   if (typeof previous === 'function') {
  #|     globalThis.removeEventListener(eventName, previous);
  #|   }
  #|   const text = (value) => (typeof value === 'string' ? value.trim() : '');
  #|   const numberText = (value) => {
  #|     const number = Number(value);
  #|     if (!Number.isFinite(number)) return '0';
  #|     return Number(number.toFixed(6)).toString();
  #|   };
  #|   const vectorText = (value) =>
  #|     [value?.x, value?.y, value?.z].map(numberText).join(' ');
  #|   const rpyText = (value) =>
  #|     [value?.roll, value?.pitch, value?.yaw].map(numberText).join(' ');
  #|   const visualIndex = (nodeId) => {
  #|     const parts = text(nodeId).split(':');
  #|     return parts.length >= 3 ? text(parts[2]) : '0';
  #|   };
  #|   const jointName = (detail) => {
  #|     const explicit = text(detail?.jointName);
  #|     if (explicit.length > 0) return explicit;
  #|     const parts = text(detail?.sourceNodeId || detail?.nodeId).split(':');
  #|     return parts[0] === 'joint' && parts.length >= 2 ? text(parts[1]) : '';
  #|   };
  #|   const listener = (event) => {
  #|     const detail = event?.detail || {};
  #|     if (detail.editable === false) return;
  #|     const nodeId = text(detail.sourceNodeId || detail.nodeId);
  #|     const kind = text(detail.kind);
  #|     const xyz = vectorText(detail.local?.xyz);
  #|     const rpy = rpyText(detail.local?.rpy);
  #|     if (kind === 'visual-origin') {
  #|       const selected = nodeId.length > 0 ? nodeId : text(detail.nodeId);
  #|       if (selected.length === 0) return;
  #|       handler(
  #|         'update-visual-origin',
  #|         selected,
  #|         text(detail.linkName),
  #|         '',
  #|         visualIndex(selected),
  #|         xyz,
  #|         rpy,
  #|       );
  #|       return;
  #|     }
  #|     if (kind === 'joint-origin') {
  #|       const name = jointName(detail);
  #|       if (name.length === 0) return;
  #|       handler(
  #|         'update-joint-origin',
  #|         `joint:${name}`,
  #|         text(detail.linkName),
  #|         name,
  #|         '',
  #|         xyz,
  #|         rpy,
  #|       );
  #|     }
  #|   };
  #|   globalThis.__moonroboUrdfTransformCommitListener = listener;
  #|   globalThis.addEventListener(eventName, listener);
  #| }

///|
#cfg(target="js")
fn register_urdf_mesh_pick_bridge(
  emit : (Msg) -> @rabbita.Cmd,
) -> @rabbita.Cmd {
  @cmd.custom_cmd(scheduler => {
    register_mesh_pick_bridge(node_id => {
      scheduler.add(emit(SelectUrdfEditorNode(node_id)))
    })
  }, kind=@cmd.after_render)
}

///|
#cfg(target="js")
fn notify_urdf_mesh_viewer_selection(node_id : String) -> @rabbita.Cmd {
  @cmd.custom_cmd(_ => notify_mesh_viewer_selection(node_id), kind=@cmd.after_render)
}

///|
#cfg(target="js")
fn register_urdf_transform_commit_bridge(
  emit : (Msg) -> @rabbita.Cmd,
) -> @rabbita.Cmd {
  @cmd.custom_cmd(scheduler => {
    register_transform_commit_bridge((
      command,
      selected_node_id,
      link_name,
      joint_name,
      visual_index,
      xyz,
      rpy,
    ) => {
      scheduler.add(
        emit(
          UrdfEditorTransformCommitted({
            command,
            selected_node_id,
            link_name,
            joint_name,
            visual_index,
            xyz,
            rpy,
          }),
        ),
      )
    })
  }, kind=@cmd.after_render)
}

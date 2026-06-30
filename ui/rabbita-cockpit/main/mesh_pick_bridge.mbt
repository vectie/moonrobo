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

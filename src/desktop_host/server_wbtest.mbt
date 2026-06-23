///|
test "desktop api recognizes task-message sidecar execution paths" {
  assert_true(
    task_id_from_execute_sidecar_path(
      "/api/moonbook/task-messages/message-walk/execute-sidecar",
    )
    is Some("message-walk"),
  )
  assert_true(
    task_id_from_execute_sidecar_path(
      "/api/moonbook/task-messages/message-walk/execute",
    )
    is None,
  )
}

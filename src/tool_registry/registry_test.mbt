///|
test "default registry exposes bounded suite capabilities" {
  let registry = @tool_registry.default_registry("noetix-e1-lab-01", 0L)
  assert_eq(registry.provider_count, 3)
  assert_eq(registry.capability_count, 14)
  assert_true(
    registry.providers.any(fn(provider) {
      provider.provider_id == "moonrobo-host-api"
    }),
  )
  assert_true(
    registry.providers.any(fn(provider) {
      provider.provider_id == "rabbita-operator-cockpit"
    }),
  )
  assert_true(
    registry.providers.any(fn(provider) {
      provider.capabilities.any(fn(capability) {
        capability.route == "/api/moonbook/conversation"
      })
    }),
  )
  assert_true(
    registry.providers.any(fn(provider) {
      provider.capabilities.any(fn(capability) {
        capability.route == "/api/moonclaw/task-loop"
      })
    }),
  )
  assert_true(@tool_registry.validate_registry(registry).is_empty())
}

///|
test "registry replaces providers by id" {
  let original = @tool_registry.default_registry("noetix-e1-lab-01", 0L)
  let replacement = @tool_registry.moonrobo_host_provider(
    "noetix-e1-lab-01", 42L,
  )
  let updated = @tool_registry.with_provider(original, replacement, 42L)
  assert_eq(updated.provider_count, 3)
  assert_eq(updated.generated_at_ms, 42L)
  let matching = updated.providers.filter(fn(provider) {
    provider.provider_id == "moonrobo-host-api"
  })
  assert_eq(matching.length(), 1)
  assert_eq(matching[0].registered_at_ms, 42L)
}

///|
test "registry rejects physical execution authority" {
  let provider = @tool_registry.moonrobo_host_provider("noetix-e1-lab-01", 0L)
  provider.capabilities[0] = {
    ..provider.capabilities[0],
    physical_execution_allowed: true,
  }
  let issues = @tool_registry.validate_provider(provider)
  assert_true(
    issues.any(fn(issue) { issue.code == "physical-tool-capability" }),
  )
}

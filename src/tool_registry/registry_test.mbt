///|
test "default registry exposes bounded suite capabilities" {
  let registry = @tool_registry.default_registry("noetix-e1-lab-01", 0L)
  assert_eq(registry.provider_count, 3)
  assert_eq(registry.capability_count, 39)
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
        capability.route == "/api/moonrobo/session"
      })
    }),
  )
  assert_true(
    registry.providers.any(fn(provider) {
      provider.capabilities.any(fn(capability) {
        capability.route == "/api/moonrobo/ask"
      })
    }),
  )
  assert_true(
    registry.providers.any(fn(provider) {
      provider.capabilities.any(fn(capability) {
        capability.route == "/api/moonrobo/loop"
      })
    }),
  )
  assert_true(
    registry.providers.any(fn(provider) {
      provider.capabilities.any(fn(capability) {
        capability.route == "/api/moonrobo/turn"
      })
    }),
  )
  assert_true(
    registry.providers.any(fn(provider) {
      provider.capabilities.any(fn(capability) {
        capability.route == "/api/moonrobo/step"
      })
    }),
  )
  assert_true(
    registry.providers.any(fn(provider) {
      provider.capabilities.any(fn(capability) {
        capability.route == "/api/moonrobo/turns"
      })
    }),
  )
  assert_true(
    registry.providers.any(fn(provider) {
      provider.capabilities.any(fn(capability) {
        capability.route == "/api/moonrobo/turns/{turn_id}"
      })
    }),
  )
  assert_true(
    registry.providers.any(fn(provider) {
      provider.capabilities.any(fn(capability) {
        capability.route == "/api/moonrobo/steps"
      })
    }),
  )
  assert_true(
    registry.providers.any(fn(provider) {
      provider.capabilities.any(fn(capability) {
        capability.route == "/api/moonrobo/loops"
      })
    }),
  )
  assert_true(
    registry.providers.any(fn(provider) {
      provider.capabilities.any(fn(capability) {
        capability.route == "/api/moonrobo/loops/{loop_id}"
      })
    }),
  )
  assert_true(
    registry.providers.any(fn(provider) {
      provider.capabilities.any(fn(capability) {
        capability.route == "/api/moonrobo/steps/{step_id}"
      })
    }),
  )
  assert_true(
    registry.providers.any(fn(provider) {
      provider.capabilities.any(fn(capability) {
        capability.route == "/api/moonrobo/decision"
      })
    }),
  )
  assert_true(
    registry.providers.any(fn(provider) {
      provider.capabilities.any(fn(capability) {
        capability.capability_id == "gateway.command" &&
        capability.route == "/api/moonrobo/gateway/command"
      })
    }),
  )
  assert_true(
    registry.providers.any(fn(provider) {
      provider.capabilities.any(fn(capability) {
        capability.capability_id == "proof.readiness" &&
        capability.route == "/api/moonrobo/live-readiness"
      })
    }),
  )
  assert_true(
    registry.providers.any(fn(provider) {
      provider.capabilities.any(fn(capability) {
        capability.route == "/api/moonrobo/proof-sessions"
      })
    }),
  )
  assert_true(
    registry.providers.any(fn(provider) {
      provider.capabilities.any(fn(capability) {
        capability.route == "/api/moonrobo/live-exercise"
      })
    }),
  )
  assert_true(
    registry.providers.any(fn(provider) {
      provider.capabilities.any(fn(capability) {
        capability.route == "/api/moonrobo/live-exercises"
      })
    }),
  )
  assert_true(
    registry.providers.any(fn(provider) {
      provider.capabilities.any(fn(capability) {
        capability.route == "/api/moonrobo/proof-sessions/{session_id}"
      })
    }),
  )
  assert_true(
    registry.providers.any(fn(provider) {
      provider.capabilities.any(fn(capability) {
        capability.route == "/api/moonrobo/live-exercises/{exercise_id}"
      })
    }),
  )
  assert_true(
    registry.providers.any(fn(provider) {
      provider.capabilities.any(fn(capability) {
        capability.capability_id == "execution.feedback-bind" &&
        capability.route == "/api/moonrobo/executions/feedback"
      })
    }),
  )
  assert_true(
    @tool_registry.find_capability(registry, "moonclaw.run-next") is None,
  )
  assert_true(
    @tool_registry.find_capability(registry, "moonclaw.context")
    is Some({ route: "/api/moonclaw/context", execution_mode: "read-only", .. }),
  )
  assert_true(
    @tool_registry.find_capability(registry, "cockpit.ask")
    is Some({ route: "/api/moonrobo/ask", execution_mode: "task-ingress", .. }),
  )
  assert_true(
    @tool_registry.find_capability(registry, "task.message")
    is Some(
      {
        route: "/api/moontown/tasks/message",
        execution_mode: "task-ledger",
        ..,
      }
    ),
  )
  assert_true(
    @tool_registry.find_capability(registry, "runtime.validation.session")
    is Some({ route: "/api/runtime/validation/session", .. }),
  )
  assert_true(
    @tool_registry.find_capability(registry, "policy.evaluate")
    is Some({ route: "/api/policies/evaluate", .. }),
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

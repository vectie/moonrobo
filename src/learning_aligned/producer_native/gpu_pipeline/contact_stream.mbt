///|
/// Primitive and convex producers may append to the SAME real stream, with
/// independent sticky rejection owners. Nothing may consume or rewrite their
/// results before the synchronized host gate. Both producers remain terminal.
fn validate_terminal_contacts(
  program : Array[Op],
  modules : Map[String, Module],
  primitive : Call?,
) -> Call? raise {
  let convex : Ref[Call?] = Ref(None)
  let mut started = false
  for operation in program {
    match operation {
      Kernel(call) => {
        let kind = modules[call.module].kind
        let contact = kind == "moonrobo-native-primitive-contact-module-v1" ||
          kind == "moonrobo-native-convex-contact-module-v1"
        guard !started || contact else {
          fail(
            "only contact append producers may follow the first terminal contact launch",
          )
        }
        if contact {
          started = true
        }
        if kind == "moonrobo-native-convex-contact-module-v1" {
          guard convex.val is None else {
            fail("one convex contact producer per terminal stream")
          }
          convex.val = Some(call)
        }
      }
      _ => {
        guard !started else {
          fail(
            "copy, zero and conditionals may not follow terminal contact producers",
          )
        }
      }
    }
  }
  if primitive is Some(a) && convex.val is Some(b) {
    let p : @narrowphase.Request = @json.from_json(modules[a.module].request)
    let c : @convex_contacts.Request = @json.from_json(
      modules[b.module].request,
    )
    guard p.nworld == c.nworld &&
      p.contact_capacity == c.contact_capacity &&
      p.efc_slots == c.efc_slots &&
      p.candidate_capacity <= (2147483647 - 8 * c.candidate_capacity) / 8 else {
      fail("combined contact stream shape or signed append bound differs")
    }
    for parameter in a.entry.parameters {
      if parameter.name == "nacon_out" || parameter.name.has_prefix("contact_") {
        guard a.named[parameter.name].to_json() ==
          b.named[parameter.name].to_json() else {
          fail(
            "terminal contact producers must append to identical owned stream views",
          )
        }
      }
    }
  }
  convex.val
}

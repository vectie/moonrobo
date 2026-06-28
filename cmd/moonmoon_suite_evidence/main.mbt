///|
fn main {
  let evidence = @moonmoon_adapter.noetix_e1_moonmoon_live_suite_evidence()
  println(evidence.to_json().stringify(indent=2))
}

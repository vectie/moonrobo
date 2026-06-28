///|
fn main {
  let contract = @moonmoon_adapter.noetix_e1_moonmoon_locomotion_contract()
  println(contract.to_json().stringify(indent=2))
}

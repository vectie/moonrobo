///|
test "rotation fixture rows decode matrices without accepting malformed trailing axes" {
  let values = Array::makei(18, i => i.to_double())
  let input : Map[String, @artifacts.NumericArray] = {
    "matrices": array([2, 3, 3], values),
    "flat": array([2, 9], values),
    "bad": array([2, 1, 3, 3, 1], values),
  }
  assert_eq(rows(input, "matrices", 9), rows(input, "flat", 9))
  assert_eq(rows(input, "matrices", 9).length(), 2)
  assert_true((try? rows(input, "bad", 9)) is Err(_))
}

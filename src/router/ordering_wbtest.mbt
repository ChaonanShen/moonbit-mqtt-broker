///|
fn sign(value : Int) -> Int {
  if value < 0 {
    -1
  } else if value > 0 {
    1
  } else {
    0
  }
}

///|
test "utf8 comparator defines lexical ascending order" {
  assert_true(compare_utf8("a", "b") < 0)
  assert_true(compare_utf8("a", "aa") < 0)
  assert_true(compare_utf8("aa", "a") > 0)
  assert_eq(compare_utf8("same", "same"), 0)
  assert_true(compare_utf8("z", "é") < 0)
  assert_true(compare_utf8("é", "😀") < 0)
  for pair in [("a", "b"), ("é", "😀"), ("alpha", "alpha")] {
    let (left, right) = pair
    assert_eq(sign(compare_utf8(left, right)), -sign(compare_utf8(right, left)))
  }
  let values = ["a", "aa", "b", "é", "😀"]
  for first in 0..<values.length() {
    for second in first..<values.length() {
      for third in second..<values.length() {
        assert_true(compare_utf8(values[first], values[second]) <= 0)
        assert_true(compare_utf8(values[second], values[third]) <= 0)
        assert_true(compare_utf8(values[first], values[third]) <= 0)
      }
    }
  }
}

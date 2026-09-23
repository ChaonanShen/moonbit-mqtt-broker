///|
test "slot reuse preserves other live slots and removes reverse keys" {
  let index = SlotIndex::new(3)
  assert_eq(index.put("a"), Added(0))
  assert_eq(index.put("b"), Added(1))
  assert_eq(index.put("c"), Added(2))
  assert_eq(index.put("a"), Existing(0))
  assert_eq(index.put("d"), Full)
  assert_true(index.remove("b"))
  assert_eq(index.get("b"), None)
  assert_eq(index.put("d"), Added(1))
  assert_eq(index.get("c"), Some(2))
  assert_eq(index.live_count(), 3)
  assert_eq(index.free_count(), 0)
  assert_true(index.check_invariants())
}

///|
test "last slot and capacity one have bounded continuation" {
  let index = SlotIndex::new(1)
  assert_eq(index.put("only"), Added(0))
  let page = index.page(0, 256, 50, fn(_) { true })
  assert_eq(page.keys, ["only"])
  assert_eq(page.scanned, 1)
  assert_false(page.has_more)
  assert_true(index.remove("only"))
  assert_eq(index.put("again"), Added(0))
  assert_true(index.check_invariants())
}

///|
test "sparse page advances without returning items" {
  let index = SlotIndex::new(600)
  assert_eq(index.put("a"), Added(0))
  let first = index.page(0, 256, 50, fn(_) { false })
  assert_eq(first.keys.length(), 0)
  assert_eq(first.next_slot, 256)
  assert_true(first.has_more)
  let second = index.page(first.next_slot, 256, 50, fn(_) { false })
  assert_eq(second.scanned, 256)
  assert_eq(second.next_slot, 512)
  let third = index.page(second.next_slot, 256, 50, fn(_) { false })
  assert_eq(third.scanned, 88)
  assert_false(third.has_more)
}

///|
test "reused scanned slot does not duplicate a surviving instance" {
  let index = SlotIndex::new(4)
  ignore(index.put("a"))
  ignore(index.put("b"))
  ignore(index.put("c"))
  let first = index.page(0, 2, 2, fn(_) { true })
  assert_eq(first.keys, ["a", "b"])
  assert_true(index.remove("a"))
  assert_eq(index.put("d"), Added(0))
  let second = index.page(first.next_slot, 2, 2, fn(_) { true })
  assert_eq(second.keys, ["c"])
  assert_false(second.has_more)
  assert_true(index.check_invariants())
}

///|
test "fixed-seed insert remove model keeps reverse map and free list sound" {
  let index = SlotIndex::new(17)
  let present = Array::make(31, false)
  let mut seed = 17
  for _ in 0..<2000 {
    seed = (seed * 109 + 89) % 10007
    let choice = seed % 31
    let key = "key-" + choice.to_string()
    if seed % 3 == 0 {
      let removed = index.remove(key)
      assert_eq(removed, present[choice])
      present[choice] = false
    } else {
      match index.put(key) {
        Added(_) => present[choice] = true
        Existing(_) => assert_true(present[choice])
        Full => assert_false(present[choice])
      }
    }
    let mut expected = 0
    for item in present {
      if item {
        expected += 1
      }
    }
    assert_eq(index.live_count(), expected)
    assert_true(index.check_invariants())
  }
}

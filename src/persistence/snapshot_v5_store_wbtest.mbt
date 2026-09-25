///|
async test "C-T31 snapshot store loads V5 envelope before listen" {
  with_store_dir("v5-envelope", path => {
    let store = SnapshotStore::open(store_config(path)).unwrap()
    let v5 = convert_v3_snapshot_to_v5(representative_snapshot()).unwrap()
    ignore(store.save_v5(v5).unwrap())
    let state = store.load_state(persistence_broker_config(), 1048576).unwrap()
    assert_true(state.uses_v5_storage())
    assert_eq(state.session_count(), 1)
    assert_eq(state.retained_count(), 1)
    store.close()
  })
}

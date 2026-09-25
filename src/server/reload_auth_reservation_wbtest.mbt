///|
async test "reload reserves online authentication capacity with an empty password database" {
  let broker_config = @router.BrokerConfig::new(4, 16, 4).unwrap()
  let config = ServerConfig::new(4, 1024, 2048, 8, 32, 1000, 100, broker_config).unwrap()
  let broker = @router.BrokerState::new(broker_config)
  let ledger = broker.resource_ledger()
  let baseline = ledger.occupied()
  let permissive = @security.SecurityPolicy::permissive()
  assert_true(create_auth_executor(config, permissive, ledger) is None)
  let reserved = create_auth_executor(
    config,
    permissive,
    ledger,
    reserve_for_reload=true,
  )
  let (worker, ticket) = match reserved {
    Some(value) => value
    None => fail("online auth reservation missing")
  }
  assert_true(ledger.occupied() > baseline)
  for _ in 0..<1000 {
    if worker.stop() == @security.ControlDone {
      break
    }
    @async.sleep(1)
  }
  for _ in 0..<1000 {
    if worker.is_stopped() == Some(true) {
      break
    }
    @async.sleep(1)
  }
  assert_eq(worker.destroy(), @security.ControlDone)
  ticket.release().unwrap()
  assert_eq(ledger.occupied(), baseline)
}

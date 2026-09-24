///|
test "restart scalar comparison uses effective defaults" {
  let baseline = effective_restart_scalars("", [])
  let explicit = effective_restart_scalars(
    "[server]\nmax_connections = 128\n",
    [],
  )
  assert_true(baseline.same_values(explicit))
  let changed = effective_restart_scalars("[server]\nmax_connections = 256\n", [])
  assert_false(baseline.same_values(changed))
  let cli = ["--max-connections", "256"]
  let first = effective_restart_scalars(
    "[server]\nmax_connections = 128\n", cli,
  )
  let overridden = effective_restart_scalars(
    "[server]\nmax_connections = 512\n", cli,
  )
  assert_true(first.same_values(overridden))
}

///|
test "restart scalar comparison treats implicit snapshot mode as effective" {
  let implicit = effective_restart_scalars(
    "[persistence]\ndata_dir = \"/srv/state\"\n",
    [],
  )
  let explicit = effective_restart_scalars(
    "[persistence]\ndata_dir = \"/srv/state\"\nmode = \"snapshot\"\n",
    [],
  )
  assert_true(implicit.same_values(explicit))
  let strict = effective_restart_scalars(
    "[persistence]\ndata_dir = \"/srv/state\"\nmode = \"strict\"\n",
    [],
  )
  assert_false(implicit.same_values(strict))
}

///|
test "restart scalar comparison detects non-hot listener address changes" {
  let baseline = effective_restart_scalars(
    "[server]\nlisten = \"127.0.0.1:1883\"\n",
    [],
  )
  let changed = effective_restart_scalars(
    "[server]\nlisten = \"127.0.0.1:1884\"\n",
    [],
  )
  assert_false(baseline.same_values(changed))
}

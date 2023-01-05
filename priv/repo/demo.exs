# Script for
#
#     mix run priv/repo/demo.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Lightning.Repo.insert!(%Lightning.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

Lightning.SetupUtils.tear_down(destroy_super: true)
Lightning.SetupUtils.setup_demo(create_super: true)
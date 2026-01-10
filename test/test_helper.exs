# Ensure a clean slate for Mnesia
:mnesia.stop()
:mnesia.delete_schema([node()])
:mnesia.start()

ExUnit.start()
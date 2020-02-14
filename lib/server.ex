
# distributed algorithms, n.dulay, 4 feb 2020
# coursework, raft consenus, v1

defmodule Server do

# using: s for 'server/state', m for 'message'

def start(config, server_id, databaseP) do
  if Map.has_key?(config.crash_servers, server_id) do
	  crash_timeout = config.crash_servers[server_id]
	  Process.send_after(self(), {:crash_timeout}, crash_timeout)
  end

  receive do
    { :BIND, servers } ->
        s = State.initialise(config, server_id, servers, databaseP)
	    s = Follower.start(s)
  end # receive

end # start

end # Server

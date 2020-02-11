
# distributed algorithms, n.dulay, 4 feb 2020
# coursework, raft consenus, v1

defmodule Server do

# using: s for 'server/state', m for 'message'

def start(config, server_id, databaseP) do
  receive do
  { :BIND, servers } ->
    s = State.initialise(config, server_id, servers, databaseP)
    # s = Follower.init(s)
    _ = Server.next(s)
  end # receive
end # start

def next(s) do
  Follower.start(s)
end # next

defp next_helper(s, votePid) do
  receive do
    {:Elected} ->
      IO.puts "I am the leader!"
      s =State.role(s, :LEADER)
    {:NewElection} ->
      s = State.curr_term(s, s[:curr_term] + 1)
      spawn(Vote, :start, [s])
  end
  next_helper(s, nil)
end

end # Server


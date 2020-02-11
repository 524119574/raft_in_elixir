
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
  # omitted
  # TODO: random 100!
  Process.send_after(self(), {:timeout}, 100 + DAC.random(100))
  next_helper(s, 0, nil)
end # next

defp next_helper(s, count, votePid) do
  receive do
    {:timeout} ->
      if count == 0 do
        # becomes candidate!
        State.role(s, :CANDIDATE)
        State.curr_term(s, s[:curr_term] + 1)
        votePId = spawn(Vote, :start, [s])
        next_helper(s, count, votePId)
      end
    {:appendEntry, leaderId, termId} ->
      if termId >= s[:curr_term] and s[:role] == :CANDIDATE do
        Process.exit votePid
        # becomes follower
        State.role(s, :FOLLOWER)
      end
    {:Elected} ->
      IO.puts "I am the leader!"
      State.role(s, :LEADER)
    {:NewElection} ->
      State.curr_term(s, s[:curr_term] + 1)
      spawn(Vote, :start, [s])
  end
  next_helper(s, count, nil)

end

end # Server


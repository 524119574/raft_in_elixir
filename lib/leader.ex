defmodule Leader do

  def start(s) do
    Monitor.debug(s, "I am the leader for term #{s[:curr_term]}")
    s = State.role(s, :LEADER)
    for server <- s[:servers], server != self(), do:
      send(server, {:appendEntry, s[:curr_term], s[:id], 0})
    Process.send_after(self(), {:resendHeartBeat}, 100)
    # Send a client request to itself.
    cmd = {:move, 100, 1, 2}
    Process.send_after(self(),
                       {:CLIENT_REQUEST, %{clientP: self(), uid: 0, cmd: cmd}},
                       50)

    next(s)
  end

  defp next(s) do
    receive do
      {:resendHeartBeat} ->
        for server <- s[:servers], server != self(), do:
          send(server, {:appendEntry, s[:curr_term], s[:id],
                        0,  # prevLogIndex
                        0,  # prevLogTerm
                        nil,
                        s[:commit_index]})
        Process.send_after(self(), {:resendHeartBeat}, 100)
      {:CLIENT_REQUEST, %{clientP: client, uid: uid, cmd: cmd}} ->
        Monitor.debug(s, "I have received a request from client in term #{s[:curr_term]}")
        prevLog = s[:log]
        # Add the client request to its own log.
        s = State.log(s, prevLog ++ [%{term: s[:curr_term], uid: uid, cmd: cmd}])
        # broadcast the appendEntry RPC.
        for server <- s[:servers], server != self(), do:
          send server, {:appendEntry, s[:curr_term], s[:id],
                        Log.getPrevLogIndex(prevLog),
                        Log.getPrevLogTerm(prevLog),
                        cmd,
                        s[:commit_index]}
      # TODO: step down when discovered server with highter term
      # {:requestVote, votePid, term, candidateId, lastLogIndex, lastLogTerm} when term > s[:curr_term] ->
      #   # need to reset voted_for and vote counts or not?
      #   Follower.start(s)

      # {:appendEntry, term, leaderId, prevLogIndex} when term > s[:curr_term] ->
      #   s = State.voted_for(s, nil)
      #   s = State.curr_term(s, term)
      #   s = State.votes(0)
      #   Follower.start(s)

    end
    next(s)
  end

end

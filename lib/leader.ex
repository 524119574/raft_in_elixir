defmodule Leader do

  def start(s) do
    Monitor.debug(s, "I am the leader for term #{s[:curr_term]}")
    s = State.role(s, :LEADER)
    for server <- s[:servers], server != self(), do:
      send(server, {:appendEntry, s[:curr_term], s[:id], 0})
    Process.send_after(self(), {:resendHeartBeat}, 100)
    next(s)
  end

  defp next(s) do
    receive do
      {:resendHeartBeat} ->
        for server <- s[:servers], server != self(), do:
          send(server, {:appendEntry, s[:curr_term], s[:id], 0})
        Process.send_after(self(), {:resendHeartBeat}, 100)
        next(s)

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
  end

end

defmodule Follower do
  def start(s) do
    s = State.role(s, :FOLLOWER)
    # TODO: random 100!
    timer = Process.send_after(self(), {:timeout}, 100 + DAC.random(500))
    next(s, timer)
  end

  defp next(s, timer) do
    receive do
      {:appendEntry, term, leaderId, prevLogIndex} ->
        # Pay attention to the off by 1 here.
        send(Enum.at(s[:servers], leaderId - 1), {:appendEntryResponse, s[:curr_term], true})
        next(s, resetTimer(timer))
      {:requestVote, votePid, term, candidateId, lastLogIndex, lastLogTerm} ->
        if term < s[:curr_term] do
          send votePid, {:requestVoteResponse, s[:curr_term], false}
        end
        if s[:voted_for] == nil or s[:voted_for] == candidateId do
          # Monitor.debug(s, "received request vote message and voted!")
          send votePid, {:requestVoteResponse, s[:curr_term], true}
        end
        next(s, resetTimer(timer))
      {:timeout} ->
        Candidate.start(s)
    end
  end

  defp resetTimer(timer) do
    Process.cancel_timer(timer)
    Process.send_after(self(), {:timeout}, (100 + DAC.random(500)))
  end

end

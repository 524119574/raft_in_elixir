defmodule Candidate do
  def start(s) do
    Monitor.debug(s, 4, "becomes candidate with log length #{Log.getLogSize(s[:log])}")
    s = State.role(s, :CANDIDATE)
    s = State.curr_term(s, s[:curr_term] + 1)
    s = State.voted_for(s, self())
    s = State.votes(s, 1)
    spawn(Vote, :start, [s, s[:curr_term]])
    next(s)
  end

  defp next(s) do
    # Monitor.debug(s, " is collecting messages as Candidate")
    receive do
      {:crash_timeout} ->
        Monitor.debug(s, 4, "crashed")
        Process.sleep(15_000)

      {:elected, term} ->
        Monitor.debug(s, 1, "received elected as leader msg")
        if (term == s[:curr_term]) do
          Leader.start(s)
        end
        next(s)

      {:newElection, term} ->
        Monitor.debug(s, 1, "received new election msg")
        if (term == s[:curr_term]) do
          Candidate.start(s)
        end
        next(s)

      {:appendEntry, term, leaderId, prevLogIndex, prevLogTerm, entries, leaderCommit} ->
        # Monitor.debug(s, "is candidate and append entry received from server #{leaderId}")
        if term >= s[:curr_term] do
          Monitor.debug(s, 4, "converts to follower from candidate in term #{s[:curr_term]} bc found leader #{leaderId} with log length #{Log.getLogSize(s[:log])}")
          s = State.curr_term(s, term)
          send Enum.at(s[:servers], leaderId - 1), {:appendEntryFailedResponse, s[:curr_term], false, self()}
          Follower.start(s)
        end
        next(s)
    end
  end #defp

end #Candidate

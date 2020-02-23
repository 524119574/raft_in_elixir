defmodule Candidate do
  def start(s) do
    Monitor.debug(s, 4, "becomes candidate with log length #{Log.getLogSize(s[:log])}")
    s = State.role(s, :CANDIDATE)
    s = State.leader_id(s, nil)
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

        Monitor.debug(s, 4, "candidate crashed and will NOT restart with log length #{Log.getLogSize(s[:log])}")
        Process.sleep(15_000)

      {:elected, term} ->

        Monitor.debug(s, 1, "candidate received elected as leader msg")
        if (term == s[:curr_term]) do
          Leader.start(s)
        end
        next(s)

      {:newElection, term} ->

        Monitor.debug(s, 1, "candidate received new election msg")
        if (term == s[:curr_term]) do
          Candidate.start(s)
        else
          next(s)
        end

      {:appendEntry, term, leaderId, prevLogIndex, prevLogTerm, entries, leaderCommit} ->

        # Monitor.debug(s, "is candidate and append entry received from server #{leaderId}")
        if term >= s[:curr_term] do
          Monitor.debug(s, 4, "converts to follower from candidate in term #{s[:curr_term]} bc found leader #{leaderId} with log length #{Log.getLogSize(s[:log])}")
          s = State.curr_term(s, term)
          send Enum.at(s[:servers], leaderId - 1), {:appendEntryFailedResponse, s[:curr_term], false, self()}
          Follower.start(s)
        else
          next(s)
        end

    end
  end #defp

end #Candidate

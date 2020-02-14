defmodule Candidate do
  def start(s) do
    # initialization
    s = State.role(s, :CANDIDATE)
    s = State.curr_term(s, s[:curr_term] + 1)
    s = State.voted_for(s, self())
    s = State.votes(s, 1)

    votePId = spawn(Vote, :start, [s])
    next(s, votePId)
  end

  defp next(s, votePId) do
    receive do
      {:crash_timeout} -> 
        Monitor.debug(s, "crashed")
        Process.sleep(15_000)

      {:Elected, term} ->
        if (term == s[:curr_term]) do
          Process.exit(votePId, :kill)
          Leader.start(s)
        else
          next(s, votePId)
        end

      {:NewElection, term} ->
        if (term == s[:curr_term]) do
          Process.exit(votePId, :kill)
          Candidate.start(s)
        else
          next(s, votePId)
        end

      {:appendEntry, term, leaderId, prevLogIndex, prevLogTerm, entries, leaderCommit} ->
        if term >= s[:curr_term] do
          Monitor.debug(s, "converts to follower from candidate in term #{s[:curr_term]} bc found leader #{leaderId}")
          s = State.curr_term(s, term)
          # TODO: append entry response format not sure if correct
          send Enum.at(s[:servers], leaderId - 1), {:appendEntryFailedResponse, s[:curr_term], false, self()}
          # Process.exit(votePId, :kill)
          Follower.start(s)
        end
    end
  end #defp

end #Candidate

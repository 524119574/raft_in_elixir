defmodule Candidate do
  def start(s) do
    s = State.role(s, :CANDIDATE)
    s = State.curr_term(s, s[:curr_term] + 1)
    s = State.voted_for(s, self())
    s = State.votes(s, 1)
    votePId = spawn(Vote, :start, [s, s[:curr_term]])
    next(s, votePId)
  end

  defp next(s, votePId) do
    # Monitor.debug(s, " is collecting messages as Candidate")
    receive do
      {:crash_timeout} ->
        Monitor.debug(s, "crashed")
        Process.sleep(15_000)

      {:Elected, term} ->
        Monitor.debug(s, "received elected as leader msg")
        if (term == s[:curr_term]) do
          # Process.exit(votePId, :kill)
          Leader.start(s)
        end
        next(s, votePId)

      {:NewElection, term} ->
        if (term == s[:curr_term]) do
          # Process.exit(votePId, :kill)
          Candidate.start(s)
        end
        next(s, votePId)

      {:appendEntry, term, leaderId, prevLogIndex, prevLogTerm, entries, leaderCommit, clientP} ->
        # Monitor.debug(s, "is candidate and append entry received from server #{leaderId}")
        if term >= s[:curr_term] do
          Monitor.debug(s, "converts to follower from candidate in term #{s[:curr_term]} bc found leader #{leaderId}")
          s = State.curr_term(s, term)
          # TODO: append entry response format not sure if correct
          send Enum.at(s[:servers], leaderId - 1), {:appendEntryFailedResponse, s[:curr_term], false, self()}
          # Process.exit(votePId, :kill)
          Follower.start(s)
        end
        next(s, votePId)
    end
  end #defp

end #Candidate

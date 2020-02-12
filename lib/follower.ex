defmodule Follower do
  def start(s) do
    s = State.role(s, :FOLLOWER)
    # TODO: random 100!
    timer = Process.send_after(self(), {:timeout}, 100 + DAC.random(500))
    next(s, timer)
  end

  defp next(s, timer) do
    receive do
      {:appendEntry, term, leaderId,
       prevLogIndex, prevLogTerm,
       entries, leaderCommit} ->
        # Monitor.debug(s, "appendentry leader: #{leaderId} term: #{term}")
        if term >= s[:curr_term] do
          if term > s[:curr_term] do
            s = State.voted_for(s, nil)
            s = State.curr_term(s, term)
          end
          # Pay attention to the off by 1 here.
          send(Enum.at(s[:servers], leaderId - 1), {:appendEntryResponse, s[:curr_term], true})
          next(s, resetTimer(timer))
        end

      # TODO: voting logic add up-do-date check in sec 5.4
      {:requestVote, votePid, term, candidateId, lastLogIndex, lastLogTerm} ->
        # Basically three cases:
        # 1. less than
        # 2. greater than
        # 3. equal
        if term < s[:curr_term] do
          send votePid, {:requestVoteResponse, s[:curr_term], false}
          next(s, resetTimer(timer))
        else
          if term > s[:curr_term] do
            s = State.curr_term(s, term)
            s = State.voted_for(s, candidateId)
            Monitor.debug(s, "term bigger: received request vote and voted for #{candidateId} in term #{term}!")
            send votePid, {:requestVoteResponse, s[:curr_term], true}
            # TODO: do we need to reset the timer here?
            next(s, resetTimer(timer))
          else
            # Not sure if the condition on term is correct though
            if (term == s[:curr_term] and
                (s[:voted_for] == nil or
                # avoid self voting!
                (s[:voted_for] == candidateId and candidateId != s[:id]))) do
              s = State.curr_term(s, term)
              s = State.voted_for(s, candidateId)
              Monitor.debug(s, "term equal: received request vote and voted for #{candidateId} in term #{term}!")
              send votePid, {:requestVoteResponse, s[:curr_term], true}
              # TODO: do we need to reset the timer here?
              next(s, resetTimer(timer))
            end
          end
        end

      {:timeout} ->
        Candidate.start(s)
    end
  end

  defp resetTimer(timer) do
    Process.cancel_timer(timer)
    Process.send_after(self(), {:timeout}, (100 + DAC.random(500)))
  end

end

defmodule Follower do
  def start(s) do
    Monitor.debug(s, "becomes follower")
    s = State.role(s, :FOLLOWER)
    s = State.voted_for(s, nil)
    s = State.votes(s, 0)
    # TODO: random 100!
    timer = Process.send_after(self(), {:timeout}, 100 + DAC.random(500))
    next(s, timer)
  end

  defp next(s, timer) do
    receive do
      { :crash_timeout } ->
        Process.cancel_timer(timer)
        Monitor.debug(s, "crashed and will sleep for 1000 ms")
        Process.sleep(1000)
        timer = Process.send_after(self(), {:timeout}, 100 + DAC.random(500))
        Monitor.debug(s, "finished sleeping and restarted")
        # IO.inspect(s[:log])
        next(s, resetTimer(timer))

      {:appendEntry, term, leaderId,
       prevLogIndex, prevLogTerm,
       entries, leaderCommit, clientP} = m ->
        s =
          cond do
            # Update current term if the term received is larger than self.
            term > s[:curr_term] -> State.curr_term(State.voted_for(s, nil), term)
            true -> s
          end
        cond do
          term < s[:curr_term] ->
            # TODO: this means leader is out-of-date right? should we send a different response to differentiate from second case
            send(Enum.at(s[:servers], leaderId - 1), {:appendEntryFailedResponse, s[:curr_term], false})
            next(s, resetTimer(timer))
          !isPreviousEntryMatch(s, prevLogIndex, prevLogTerm) ->
            IO.puts "previous entry not matching case"
            send(Enum.at(s[:servers], leaderId - 1), {:appendEntryFailedResponse, s[:curr_term], false, self()})
            next(s, resetTimer(timer))
          entries != nil ->
            s = State.log(s, Enum.concat(s[:log], (for entry <- entries, do: entry)))
            send(Enum.at(s[:servers], leaderId - 1), {:appendEntryResponse, s[:curr_term], true, m, self(), Log.getPrevLogIndex(s[:log])})
            Monitor.debug(s, "Log updated log length #{length(s[:log])} cur term: #{s[:curr_term]}")
            # update commit index if necessary
            s = State.commit_index(s, if leaderCommit > s[:commit_index]
                                      do min(leaderCommit, length(s[:log]))
                                      else s[:commit_index] end)
            # update last applied if necessary, might have off by 1 problems
            if s[:commit_index] > s[:last_applied] do
              s = State.last_applied(s, s[:last_applied] + 1)
              send s[:databaseP], {:EXECUTE, Enum.at(s[:log], s[:last_applied] - 1)[:cmd]}
              next(s, resetTimer(timer))
            end
            next(s, resetTimer(timer))
          # Question: how to differentiate hearbeat response from append entry response?

          # heartbeat
          true ->
            # Monitor.debug(s, "received hearbeat")
            send(Enum.at(s[:servers], leaderId - 1), {:appendEntryResponse, s[:curr_term], true})
            s = State.commit_index(s, if leaderCommit > s[:commit_index]
                                      do min(leaderCommit, length(s[:log]))
                                      else s[:commit_index] end)
            # update last applied if necessary
            if s[:commit_index] > s[:last_applied] do
              s = State.last_applied(s, s[:last_applied] + 1)
              send s[:databaseP], {:EXECUTE, Enum.at(s[:log], s[:last_applied] - 1)[:cmd]}
              next(s, resetTimer(timer))
            end
            next(s, resetTimer(timer))
        end

      # TODO: voting logic not sure if entirely correct
      {:requestVote, votePid, term, candidateId, lastLogIndex, lastLogTerm} ->
        s =
        cond do
          # Update current term if the term received is larger than self.
          term > s[:curr_term] -> State.curr_term(State.voted_for(s, nil), term)
          true -> s
        end
        up_to_date = lastLogTerm > Log.getPrevLogTerm(s[:log]) or
                    (lastLogTerm == Log.getPrevLogTerm(s[:log]) and lastLogIndex >= Log.getPrevLogIndex(s[:log]))
        cond do
          term > s[:curr_term] and up_to_date ->
            s = State.curr_term(s, term)
            s = State.voted_for(s, candidateId)
            Monitor.debug(s, "term bigger: received request vote and voted for #{candidateId} in term #{term}!")
            send votePid, {:requestVoteResponse, s[:curr_term], true}
            # TODO: do we need to reset the timer here?
            next(s, resetTimer(timer))
          term == s[:curr_term] and up_to_date and (s[:voted_for] == nil or s[:voted_for] == candidateId) ->
            s = State.voted_for(s, candidateId)
            Monitor.debug(s, "term equal: received request vote and voted for #{candidateId} in term #{term}!")
            send votePid, {:requestVoteResponse, s[:curr_term], true}
            # TODO: do we need to reset the timer here?
            next(s, resetTimer(timer))
          true ->
            send votePid, {:requestVoteResponse, s[:curr_term], false}
            next(s, resetTimer(timer))
        end

      # TODO: forward client request to current leader
      # {:CLIENT_REQUEST, %{clientP: client, uid: uid, cmd: cmd}} ->
      #   # how do follower know the address of leader?
      #   next(s, timer)

      {:timeout} ->
        Monitor.debug(s, "converts to candidate from follower in term #{s[:curr_term]} (+1)")
        Candidate.start(s)
    end
  end

  defp resetTimer(timer) do
    Process.cancel_timer(timer)
    Process.send_after(self(), {:timeout}, (100 + DAC.random(500)))
  end

  defp isPreviousEntryMatch(s, prevLogIndex, prevLogTerm) do
    (length(s[:log]) >= prevLogIndex and
     (prevLogIndex == 0 or
      Enum.at(s[:log], prevLogIndex - 1)[:term] == prevLogTerm))
  end

end

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
      # TODO: not sure if timer related things are needed
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

        # leader who sent the message is out-of-date
        if term < s[:curr_term] do
          send(Enum.at(s[:servers], leaderId - 1), {:appendEntryFailedResponse, s[:curr_term], false, self()})
          next(s, resetTimer(timer))
        end
        # Update current term and voted for if the term received is larger than self.
        s =
          cond do
            term > s[:curr_term] -> State.curr_term(State.voted_for(s, nil), term)
            true -> s
          end

        cond do
          # heartbeat
          entries == nil ->
            # Monitor.debug(s, "received hearbeat from #{leaderId} whose commit index is #{leaderCommit}")
            # send(Enum.at(s[:servers], leaderId - 1), {:appendEntryResponse, s[:curr_term], true})
            s = State.commit_index(s, if leaderCommit > s[:commit_index]
                                      do min(leaderCommit, Log.getLogSize(s[:log]))
                                      else s[:commit_index] end)
            # update last applied if received higher commit index
            if s[:commit_index] > s[:last_applied] do
              num_to_commit = s[:commit_index] - s[:last_applied]
              for i <- 1..s[:commit_index] - s[:last_applied] do
                send s[:databaseP], {:EXECUTE, s[:log][s[:last_applied] + i][:cmd]}
              end
              s = State.last_applied(s, s[:commit_index])
              Monitor.debug(s, "heartbeat increment last_applied follower last applied is #{s[:last_applied]}")
              next(s, resetTimer(timer))
            end
            next(s, resetTimer(timer))

          !isPreviousEntryMatch(s, prevLogIndex, prevLogTerm) ->
            Monitor.debug(s, "previous entry not matching")
            Monitor.debug(s, "follower rcved entry #{inspect(Enum.at(entries, 0))} with prevLogIndex #{prevLogIndex} term #{prevLogTerm}")
            send(Enum.at(s[:servers], leaderId - 1), {:appendEntryFailedResponse, s[:curr_term], false, self()})
            next(s, resetTimer(timer))

          true ->
            s = State.commit_log(s, Enum.at(entries, 0)[:uid], false)
            # use smart enum function to do concat and insert at the same time?
            if isCurrentEntryMatch(s, prevLogIndex + 1, Enum.at(entries, 0)[:term], Enum.at(entries, 0)[:uid]) do
              s = State.commit_log(s, Enum.at(entries, 0)[:uid], true)
              s = State.commit_index(s, if leaderCommit > s[:commit_index]
                                        do min(leaderCommit, Log.getLogSize(s[:log]))
                                        else s[:commit_index] end)
              send(Enum.at(s[:servers], leaderId - 1), {:appendEntryResponse, s[:curr_term], true, m, self(), prevLogIndex + 1})
              # Monitor.debug(s, "current entry matches, didn't do anything")
              next(s, resetTimer(timer))
            end

            s = State.log(
              s, Enum.reduce(entries, s[:log],
                             fn entry, log -> Log.appendNewEntry(log, entry) end))
            # s = State.log(s, Enum.slice(s[:log], 0..prevLogIndex) ++ entries)
            send(Enum.at(s[:servers], leaderId - 1), {:appendEntryResponse, s[:curr_term], true, m, self(), prevLogIndex + 1})
            # Monitor.debug(s, "Log updated log length #{length(s[:log])} cur term: #{s[:curr_term]}")
            # update commit index if necessary
            s = State.commit_index(s, if leaderCommit > s[:commit_index]
                                      do min(leaderCommit, Log.getLogSize(s[:log]))
                                      else s[:commit_index] end)
            # Monitor.debug(s, "follower commit index is #{s[:commit_index]} rcved from leader is #{leaderCommit}")

            # update last applied if necessary, might have off by 1 problems
            if s[:commit_index] > s[:last_applied] do
              # IO.puts "cmt - apply is #{s[:commit_index] - s[:last_applied]}"
              num_to_commit = s[:commit_index] - s[:last_applied]
              for i <- 1..num_to_commit do
                send s[:databaseP], {:EXECUTE, s[:log][s[:last_applied] + i][:cmd]}
              end
              # TODO: ADD COMMIT_LOG
              s = State.last_applied(s, s[:commit_index])
              # Monitor.debug(s, "follower last applied is #{s[:last_applied]}")
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
        Process.cancel_timer(timer)
        Candidate.start(s)
    end
  end

  defp resetTimer(timer) do
    Process.cancel_timer(timer)
    Process.send_after(self(), {:timeout}, (100 + DAC.random(500)))
  end

  defp isPreviousEntryMatch(s, prevLogIndex, prevLogTerm) do
    # Monitor.debug(s, "prev entry look at #{inspect(Enum.at(s[:log], prevLogIndex - 1))}")
    (Log.getLogSize(s[:log]) >= prevLogIndex and
     (prevLogIndex == 0 or s[:log][prevLogIndex][:term] == prevLogTerm))
  end

  defp isCurrentEntryMatch(s, curEntryIndex, curEntryTerm, curEntryUid) do
    # Monitor.debug(s, "current entry look at #{inspect(Enum.at(s[:log], prevLogIndex))}")
    currentEntry = s[:log][curEntryIndex]
    (Log.getLogSize(s[:log]) >= curEntryIndex and
    (currentEntry[:term] == curEntryTerm) and
    (currentEntry[:uid] == curEntryUid))
  end

end

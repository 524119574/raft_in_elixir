defmodule Follower do
  def start(s) do
    Monitor.debug(s, 4, "becomes follower with log length #{Log.get_log_size(s[:log])}")
    s = State.role(s, :FOLLOWER)
    s = State.voted_for(s, nil)
    s = State.votes(s, 0)
    timer = Process.send_after(self(), {:timeout}, s.config.election_timeout + DAC.random(s.config.election_timeout))
    Process.send_after(self(), {:crash_and_restart}, 3000)
    next(s, timer)
  end

  defp next(s, timer) do

    receive do

      {:crash_timeout} ->

        Monitor.debug(s, 4, "follower crashed and will NOT restart with log length #{Log.get_log_size(s[:log])}")
        Process.sleep(30_000)

      {:crash_and_restart} ->

        Process.cancel_timer(timer)
        Monitor.debug(s, 4, "follower crashed and will sleep for 1000 ms")
        Process.sleep(1000)
        Monitor.debug(s, 4, "follower finished sleeping and restarted")
        next(s, reset_timer(timer, s.config.election_timeout))

      {:append_entry, term, leader_id,
       prev_log_index, prev_log_term,
       entries, leader_commit} ->

        # Update current term and voted for if the term received is larger than self.
        s = cond do
              term > s[:curr_term] -> State.curr_term(State.voted_for(s, nil), term)
              true -> s
            end

        # save the leader id in current term
        s = cond do
              leader_id != s[:leader_id] or s[:leader_id] == nil -> State.leader_id(s, leader_id)
              true -> s
            end

        s = cond do
              leader_commit > s[:last_applied] ->

                s = State.commit_index(s, leader_commit)
                commit_entries(s)

              true -> s
            end

        cond do
          term < s[:curr_term] ->

            send(Enum.at(s[:servers], leader_id - 1), {:append_entry_response, s[:curr_term], false, self(), nil})
            next(s, reset_timer(timer, s.config.election_timeout))

          entries == nil -> # heartbeat

            next(s, reset_timer(timer, s.config.election_timeout))

          !is_entry_match(s, prev_log_index, prev_log_term) ->
            # Monitor.debug(s, 2, "follower rcved entry #{inspect(entries)} with prev_log_index #{prev_log_index} term #{prev_log_term}")
            # Monitor.debug(s, 2, "before deleting log length is #{Log.get_log_size(s[:log])})"

            # The max also handle the case where the log is shorter.
            s = State.log(s, Log.delete_n_entries_from_last(s[:log], max(Log.get_log_size(s[:log]) - prev_log_index + 1, 0)))
            # Monitor.debug(s, 2, "after deleting log length is #{Log.get_log_size(s[:log])})"
            send(Enum.at(s[:servers], leader_id - 1), {:append_entry_response, s[:curr_term], false, nil})
            next(s, reset_timer(timer, s.config.election_timeout))

          true ->
            # Remove all entries after the prevIndex but not including the prevIndex
            s = State.log(s, Log.delete_n_entries_from_last(s[:log], Log.get_log_size(s[:log]) - prev_log_index))
            s = State.log(
              s, Enum.reduce(entries, s[:log],
                             fn entry, log -> Log.append_new_entry(log, entry, prev_log_index + 1, entry[:term]) end))
            # Monitor.debug(s, 2, "Log updated log length #{length(s[:log])} cur term: #{s[:curr_term]}")

            s = State.commit_index(s, if leader_commit > s[:commit_index]
                                      do min(leader_commit, Log.get_log_size(s[:log]))
                                      else s[:commit_index] end)

            s = commit_entries(s)
            send(Enum.at(s[:servers], leader_id - 1),
                 {:append_entry_response, s[:curr_term], true, self(), Log.get_prev_log_index(s[:log])})
            Monitor.debug(s, "Updated log length #{Log.get_log_size(s[:log])}," <>
              "last applied: #{s[:last_applied]} #{inspect(s[:log][s[:last_applied]])} commit index: #{leader_commit}")
            next(s, reset_timer(timer, s.config.election_timeout))

        end

      {:request_vote, vote_pid, term, candidate_id, last_log_index, lastLogTerm} ->
        s =
        cond do
          # Update current term if the term received is larger than self.
          term > s[:curr_term] -> State.curr_term(State.voted_for(s, nil), term)
          true -> s
        end
        up_to_date = lastLogTerm > Log.get_prev_log_term(s[:log]) or
                    (lastLogTerm == Log.get_prev_log_term(s[:log]) and last_log_index >= Log.get_prev_log_index(s[:log]))
        cond do
          term > s[:curr_term] and up_to_date ->
            s = State.voted_for(s, candidate_id)
            # Monitor.debug(s, 1, "term bigger: received request vote and voted for #{candidate_id} in term #{term}!")
            send vote_pid, {:request_vote_response, s[:curr_term], true}
            next(s, reset_timer(timer, s.config.election_timeout))
          term == s[:curr_term] and up_to_date and (s[:voted_for] == nil or s[:voted_for] == candidate_id) ->
            s = State.voted_for(s, candidate_id)
            # Monitor.debug(s, 1, "term equal: received request vote and voted for #{candidate_id} in term #{term}!")
            send vote_pid, {:request_vote_response, s[:curr_term], true}
            next(s, reset_timer(timer, s.config.election_timeout))
          true ->
            send vote_pid, {:request_vote_response, s[:curr_term], false}
            next(s, reset_timer(timer, s.config.election_timeout))
        end

      {:CLIENT_REQUEST, %{clientP: client, uid: uid, cmd: cmd}} ->

        if s[:leader_id] != nil do
          Monitor.debug(s, 2, "follower forwarded client request to leader #{s[:leader_id]}")
          send(Enum.at(s[:servers], s[:leader_id] - 1), {:CLIENT_REQUEST, %{clientP: client, uid: uid, cmd: cmd}})
        end

        Monitor.debug(s, 2, "follower received client request but do not know leader")
        next(s, reset_timer(timer, s.config.election_timeout))

      {:timeout} ->

        Monitor.debug(s, 4, "converts to candidate from follower in term #{s[:curr_term]} (+1)")
        Process.cancel_timer(timer)
        Candidate.start(s)

    end
  end

  defp reset_timer(timer, timeout) do
    Process.cancel_timer(timer)
    Process.send_after(self(), {:timeout}, timeout + DAC.random(timeout))
  end

  defp is_entry_match(s, prev_log_index, prev_log_term) do
    # Monitor.debug(s, 2, "prev entry look at #{inspect(Enum.at(s[:log], prev_log_index - 1))}")
    (prev_log_index == 0 or s[:log][prev_log_index][:term] == prev_log_term)
  end

  defp commit_entries(s) do
    if s[:commit_index] > s[:last_applied] do
      num_to_execute = s[:commit_index] - s[:last_applied]
      Monitor.debug(s, "committing some log: #{inspect(Log.get_entries_between(s[:log], s[:last_applied] + 1, s[:commit_index]))}")
      for i <- 1..num_to_execute do
        send s[:databaseP], {:EXECUTE, s[:log][s[:last_applied] + i][:cmd]}
      end
      s = State.last_applied(s, s[:commit_index])
      Monitor.debug(s, "committed some log: " <>
      "log length #{Log.get_log_size(s[:log])}, " <>
      "last applied == commitIndex: #{s[:last_applied]}")
      s
    else
      s
    end
  end


end

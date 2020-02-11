defmodule Vote do

  def start(s) do
    # Monitor.debug(s, "Voting started!")
    next(s)
  end

  defp next(s) do
    s = State.voted_for(s, self())
    s = State.votes(s, s[:votes] + 1)

    for server <- s[:servers], server != self(), do:
      # We added a vote pid(self) so that people know how to send the message back,
      # this is an additional attributes on top of the normal RAFT attributes.
      send server, {:requestVote, self() ,s[:curr_term], s[:id], 0, 0}

    #TODO: change the time
    Process.send_after(self(), {:voteTimeOut}, (100 + DAC.random(100)))

    collectVotes(s)

    if s[:votes] >= s[:majority] do
      send s[:selfP], {:Elected, s[:curr_term]}
    else
      send s[:selfP], {:NewElection, s[:curr_term]}
    end
  end

  defp collectVotes(s) do
    Monitor.debug(s, "inside collect vote!")
    receive do
      {:voteTimeOut} ->
        IO.puts "timeout... so sad...."
      {:requestVoteResponse, term, true} ->
        s = State.votes(s, s[:votes] + 1)
        # Monitor.debug(s, "collected one vote!!! The total vote is #{s[:votes]}")
        if s[:votes] == s[:majority] do
          send s[:selfP], {:Elected, s[:curr_term]}
        else
          collectVotes(s)
        end
      {:requestVoteResponse, term, false} ->
        Monitor.debug(s, "error.....")
    end

    collectVotes(s)

  end

end

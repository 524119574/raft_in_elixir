defmodule Vote do

  def start(s) do
    IO.puts "Voting started!"
    next(s)
  end

  defp next(s) do
    State.voted_for(s, self())
    State.votes(s, s[:votes] + 1)

    for server <- s[:servers], server != self(), do:
      send server, {:requestVote, s[:curr_term], s[:id]}

    #TODO: change the time
    Process.send_after(self(), {:voteTimeOut}, 100 + DAC.random(100))

    collectVotes(s)

    if s[:votes] >= s[:majority] do
      # becomes leader!
      send s[:selfP], {:Elected}
    else
      send s[:selfP], {:NewElection}
    end
  end

  defp collectVotes(s) do
    IO.puts "inside collect vote!"
    receive do
      {:voteTimeOut, value} ->
        i = 1
      {:vote, term} ->
        s.votes(s, s[:votes] + 1)
        collectVotes(s)
    end

  end

end

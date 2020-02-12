defmodule Leader do

  def start(s) do
    Monitor.debug(s, "I am the leader for term #{s[:curr_term]}")
    s = State.role(s, :LEADER)
    for server <- s[:servers], server != self(), do:
      send(server, {:appendEntry, s[:curr_term], s[:id], 0})
    Process.send_after(self(), {:resendHeartBeat}, 100)
    next(s)
  end

  defp next(s) do
    receive do
      {:resendHeartBeat} ->
        for server <- s[:servers], server != self(), do:
          send(server, {:appendEntry, s[:curr_term], s[:id], 0})
    end
    Process.send_after(self(), {:resendHeartBeat}, 100)
    next(s)
  end

end

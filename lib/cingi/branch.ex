defmodule Cingi.Branch do
	@moduledoc """
	Branches manage the missions for a single node.
	They intialize missions and mission reports,
	and assign or create the outposts for missions to be sent
	to. Although they initialize missions, they send missions
	over to a single Headquarters which reassigns the missions
	to an appropriate branch based on capacity.
	"""

	alias Cingi.Branch
	alias Cingi.Headquarters
	alias Cingi.Outpost
	alias Cingi.Mission
	alias Cingi.MissionReport
	use GenServer

	defstruct [
		node: nil,
		pid: nil,
		name: nil,

		hq_pid: nil,
		cli_pid: nil, # Get cli pid if run through cli

		running: true,
		mission_reports: [],
		started_missions: [],
		running_missions: [],
		finished_missions: [],
	]

	def start_link(args \\ []) do
		GenServer.start_link(__MODULE__, args, [name: args[:name]])
	end

	def create_report(pid, yaml_tuple) do
		GenServer.call(pid, {:yaml, yaml_tuple})
	end

	def queue_report(pid, yaml_tuple) do
		GenServer.cast(pid, {:yaml, yaml_tuple})
	end

	def init_mission(pid, opts) do
		GenServer.cast(pid, {:init_mission, opts})
	end

	def run_mission(pid, mission) do
		GenServer.cast(pid, {:run_mission, mission, Node.self})
	end

	def send_mission_to_outpost(pid, mission_pid, alternates_node) do
		GenServer.cast(pid, {:outpost_for_mission, mission_pid, alternates_node})
	end

	def mission_has_run(pid, mission_pid) do
		GenServer.cast(pid, {:mission_has_run, mission_pid})
	end

	def mission_has_finished(pid, mission_pid, result) do
		GenServer.cast(pid, {:mission_has_finished, mission_pid, result})
	end

	def report_has_finished(pid, report_pid, mission_pid) do
		GenServer.cast(pid, {:report_has_finished, report_pid, mission_pid})
	end

	def outpost_data(pid, outpost_pid, data) do
		GenServer.cast(pid, {:outpost_data, outpost_pid, data})
	end

	def report_data(pid, report_pid, data) do
		GenServer.cast(pid, {:report_data, report_pid, data})
	end

	def pause(pid) do
		GenServer.call(pid, :pause)
	end

	def resume(pid) do
		GenServer.call(pid, :resume)
	end

	def get(pid) do
		GenServer.call(pid, :get)
	end

	def terminate(pid) do
		GenServer.call(pid, :terminate)
	end

	def link_headquarters(pid, hq_pid) do
		GenServer.call(pid, {:link_headquarters, hq_pid})
	end

	def link_cli(pid, cli_pid) do
		GenServer.call(pid, {:link_cli, cli_pid})
	end

	# Server Callbacks

	def init(opts) do
		branch = %Branch{
			node: Node.self,
			pid: self(),
			name: opts[:name],
			hq_pid: nil,
		}
		{:ok, branch}
	end

	def handle_call({:yaml, yaml_tuple}, _from, branch) do
		{missionReport, branch} = get_branch_and_new_report(branch, yaml_tuple)
		{:reply, missionReport, branch}
	end

	def handle_call(:pause, _from, branch) do
		branch = %Branch{branch | running: false}
		for m <- branch.running_missions do Mission.pause(m) end
		{:reply, branch, branch}
	end

	def handle_call(:resume, _from, branch) do
		branch = %Branch{branch | running: true}
		for m <- branch.running_missions do Mission.resume(m) end
		Headquarters.run_missions(branch.hq_pid)
		{:reply, branch, branch}
	end

	def handle_call(:get, _from, branch) do
		{:reply, branch, branch}
	end

	def handle_call({:link_headquarters, hq_pid}, _from, branch) do
		branch = %Branch{branch | hq_pid: hq_pid}
		{:reply, branch, branch}
	end

	def handle_call({:link_cli, cli_pid}, _from, branch) do
		branch = %Branch{branch | cli_pid: cli_pid}
		{:reply, branch, branch}
	end

	def handle_call(:terminate, _from, branch) do
		if (branch.cli_pid) do
			send branch.cli_pid, :terminate
		end
		{:reply, branch, branch}
	end

	def handle_cast({:yaml, yaml_tuple}, branch) do
		{_, branch} = get_branch_and_new_report(branch, yaml_tuple)
		{:noreply, branch}
	end

	def handle_cast({:init_mission, opts}, branch) do
		{:ok, mission} = Mission.start_link(opts)

		# Report passes in opts of the report_pid and outpost_pid
		# If there is an outpost_pid, then an outpost sent the report
		case opts[:outpost_pid] do
			# No outpost_pid, sne dto hq for distribution
			nil -> Headquarters.queue_mission(branch.hq_pid, mission)

			# outpost_pid, bypass hq and run on this branch
			_ -> Branch.run_mission(self(), mission)
		end
		{:noreply, branch}
	end

	def handle_cast({:run_mission, mission, alternates_node}, branch) do
		Branch.send_mission_to_outpost(self(), mission, alternates_node)
		branch = %Branch{branch | started_missions: branch.started_missions ++ [mission]}
		{:noreply, branch}
	end

	# Getting of the outpost should be handled by the specific Branch 
	# Because a Mission could have initialized at a different Branch
	# than the one currently running it, so the outpost that's retrieved
	# should be the one on the same node as the Branch running the mission
	def handle_cast({:outpost_for_mission, mission_pid, alternates_node}, branch) do
		mission = Mission.get(mission_pid)

		# The parent outpost process is either the outpost of its supermission
		# or potentially the parent of the outpost that started the mission_report,
		# as that outpost would be for setting up and needs its parent environnment to do so
		base_outpost = case mission.supermission_pid do
			nil ->
				case MissionReport.get(mission.report_pid).outpost_pid do
					nil -> nil
					opid ->
						o = Outpost.get(opid)
						# Use the outpost itself if it's already setup,
						# otherwise use it's parent so its setup can be run on
						# an already setup outpost
						if o.is_setup do opid else o.parent_pid end
				end
			supermission -> Mission.get_outpost(supermission)
		end

		outpost_opts = [
			branch_pid: self(),
			plan: Mission.get_outpost_plan(mission_pid),
			parent_pid: base_outpost,
			root_mission_pid: mission_pid,
			alternates: :rpc.call(alternates_node, Outpost, :start_alternates, [mission_pid]),
		]

		# See if mission has an outpost configuration
		# if so, use that to start initialize a new outpost,
		# otherwise use an outpost from this mission's supermission,
		# constructing on this node if necessary
		{:ok, outpost} = case {outpost_opts[:plan], base_outpost} do
			{nil, nil} -> Outpost.start_link(outpost_opts)
			{nil, base_outpost} -> Outpost.get_or_create_version_on_branch(base_outpost, self())
			_ -> Outpost.start_link(outpost_opts)
		end

		Outpost.run_mission(outpost, mission_pid)
		{:noreply, branch}
	end

	def handle_cast({:mission_has_run, mission_pid}, branch) do
		started_missions = cond do
			mission_pid in branch.started_missions -> List.delete(branch.started_missions, mission_pid)
			true -> raise "Mission ran but not started"
		end
		Headquarters.run_missions(branch.hq_pid)
		{:noreply, %Branch{branch |
			started_missions: started_missions,
			running_missions: branch.running_missions ++ [mission_pid],
		}}
	end

	def handle_cast({:mission_has_finished, mission_pid, result}, branch) do
		running_missions = cond do
			mission_pid in branch.running_missions ->
				List.delete(branch.running_missions, mission_pid)
			true ->
				IO.puts :stderr, "Mission finished but not ran #{inspect(Mission.get(mission_pid))}"
				branch.running_missions
		end

		Headquarters.finished_mission(branch.hq_pid, mission_pid, result, self())

		{:noreply, %Branch{branch |
			running_missions: running_missions,
			finished_missions: branch.finished_missions ++ [mission_pid],
		}}
	end

	def handle_cast({:report_has_finished, report_pid, mission_pid}, branch) do
		if (branch.cli_pid) do
			send branch.cli_pid, {:report, report_pid, mission_pid}
		end
		{:noreply, branch}
	end

	def handle_cast({:outpost_data, _outpost_pid, data}, branch) do
		if (branch.cli_pid) do
			send branch.cli_pid, {:branch_outpost_data, data}
		end
		{:noreply, branch}
	end

	def handle_cast({:report_data, _report_pid, data}, branch) do
		if (branch.cli_pid) do
			send branch.cli_pid, {:branch_report_data, data}
		end
		{:noreply, branch}
	end

	def get_branch_and_new_report(branch, yaml_tuple) do
		{:ok, missionReport} = MissionReport.start_link(yaml_tuple ++ [branch_pid: self()])
		reports = branch.mission_reports ++ [missionReport]
		{missionReport, %Branch{branch | mission_reports: reports}}
	end
end

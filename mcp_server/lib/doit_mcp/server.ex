defmodule DoitMcp.Server do
  @moduledoc """
  The Do It List MCP server (m03.03) — a thin stdio adapter over `/api/v1`
  (Arc 1). Holds no domain logic; every tool/resource is a translation layer
  that calls `DoitMcp.Client`, the only module that speaks HTTP.
  """

  use Anubis.Server,
    name: "doit-list",
    version: "0.1.0",
    capabilities: [:tools, :resources]

  # Task
  component(DoitMcp.Tools.CreateTask)
  component(DoitMcp.Tools.UpdateTask)
  component(DoitMcp.Tools.CompleteTask)
  component(DoitMcp.Tools.MoveTask)
  component(DoitMcp.Tools.SetTaskCoAssignees)
  component(DoitMcp.Tools.DeleteTask)

  # Initiative
  component(DoitMcp.Tools.CreateInitiative)
  component(DoitMcp.Tools.UpdateInitiative)
  component(DoitMcp.Tools.SetInitiativeState)
  component(DoitMcp.Tools.GetInitiativeActivity)

  # Comment
  component(DoitMcp.Tools.AddComment)
  component(DoitMcp.Tools.EditComment)
  component(DoitMcp.Tools.DeleteComment)

  # Member
  component(DoitMcp.Tools.AddMember)
  component(DoitMcp.Tools.UpdateMemberRole)
  component(DoitMcp.Tools.RemoveMember)

  # Notification
  component(DoitMcp.Tools.MarkNotificationRead)

  # Cross-reference (link)
  component(DoitMcp.Tools.AddLink)
  component(DoitMcp.Tools.RemoveLink)

  # Batch (atomic multi-op, lid forward-refs)
  component(DoitMcp.Tools.ApplyOperations)

  # Resources — mirror the read surface 1:1
  component(DoitMcp.Resources.Me)
  component(DoitMcp.Resources.Initiatives)
  component(DoitMcp.Resources.InitiativeTree)
  component(DoitMcp.Resources.InitiativeActivity)
  component(DoitMcp.Resources.InitiativeMembers)
  component(DoitMcp.Resources.TaskComments)
end

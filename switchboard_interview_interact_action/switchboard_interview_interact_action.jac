import logging;
import from logging { Logger }
import from typing { Optional, List, Dict }
import from jivas.agent.action.interview_interact_action { InterviewInteractAction, InterviewSession, SessionState }
import from jivas.agent.action.agent_graph_walker { agent_graph_walker }
import from jivas.agent.modules.system.common { node_obj }


node SwitchboardInterviewInteractAction(InterviewInteractAction) {
    static has logger:Logger = logging.getLogger(__name__);
    has description:str = "This action allows the user to choose the agent they want to interact with.";
    has available_agents: list[dict] = [];
    has auto_confirm:bool = True;
    has history_size: int = 1;
    has switchboard_interact_action: str = "SwitchboardInteractAction";

    # Override question_index from base InterviewInteractAction
    has question_index:dict = {
        "selected_agent": {
            "question": "Please select an agent you wish to be routed to:",
            "constraints": {
                "description": "Extract selected_agent as the Id of the agent explicitly mentioned by name from the provided list. Only return the Id if the user directly references an agent by name.",
                "type": "string",
                "agents": []
            },
            "required": True
        }
    };

    # Override prompts for a more tailored experience
    has available_agents_directive:str = "Present these agents to the user and ask them to choose a single agent from the list:\n\n{agents}";

    has confirmed_directive: str = """
    You successfully selected an agent and routed the user. Inform the user by:
    a. Directly and concisely stating: "Thank you! You've selected: **{selected_agent_name}**.
    You will now be directed to services for this area. If you wish to change this later, you can say "change agent" or similar.".
    b. Do not include any additional statements.
    """;

    has aborted_directive: str = """
    You aborted routing to an agent. Inform the user by:
    a. Directly and concisely stating: "Okay, I've cancelled your booking.".
    b. Do not include any additional statements.
    """;

    has failed_directive: str = """
    You tried to route to an agent but failed. Inform the user by:
    a. Directly and concisely stating: "Sorry, I'm unable to route you to an agent.".
    b. Do not include any additional statements.
    """;


    def touch(visitor: agent_graph_walker) -> bool {
        switchboard_interact_action = self.get_agent().get_action(action_label=self.switchboard_interact_action);
        current_subscription = switchboard_interact_action.get_user_location_subscription(user_session_id=visitor.session_id);

        if not current_subscription {
            available_agents = switchboard_interact_action.get_available_agents();
            self.question_index["selected_agent"]["constraints"]["agents"] = available_agents;
            return True;
        }
        return False;
    }


    def process_response(interview_session: InterviewSession, visitor: agent_graph_walker) {

        # pass response as a directive
        if visitor.interaction_node.has_response() {
            message = visitor.interaction_node.get_message();
            visitor.interaction_node.add_directive(f"Inform the user about the following message: {message}.");
            visitor.interaction_node.response = {};
        }

        switchboard_interact_action = self.get_agent().get_action(action_label=self.switchboard_interact_action);
        if not switchboard_interact_action {
            self.logger.error(f"Subscription Manager Action '{self.switchboard_interact_action}' not found!");
            visitor.interaction_node.add_directive(directive=self.failed_directive);
            interview_session.set_state(SessionState.ABORTED);
        }

        available_agents = self.question_index["selected_agent"]["constraints"]["agents"];

        if(interview_session.get_state() == SessionState.OPEN) {
            if next_directive := self.get_next_question_directive(interview_session) {
                visitor.interaction_node.add_directive(directive=next_directive);
            }else {
                interview_session.set_state(SessionState.COMPLETED);
            }

            # check if active field is selected_agent and pass available agents
            if(interview_session.active_field == "selected_agent") {
                visitor.interaction_node.add_directive(directive=self.available_agents_directive.format(agents=available_agents));
            }
        }


        if (interview_session.get_state() == SessionState.CONFIRMED) {
            selected_agent_id = interview_session.get_response("selected_agent");
            selected_agent_info = {};
            for agent in available_agents {
                if agent["id"] == selected_agent_id {
                    selected_agent_info = agent;
                    break;
                }
            }

            if (selected_agent_info) {
                selected_agent_name = selected_agent_info.get("name", "");
                switchboard_interact_action.update_user_location_subscription(
                    user_session_id=visitor.session_id,
                    agent_id=selected_agent_id,
                    agent_name=selected_agent_name
                );

                visitor.interaction_node.add_directive(self.confirmed_directive.format(selected_agent_name=selected_agent_name));
            } else {
                self.logger.error(f"State is CONFIRMED but selected_location ID '{selected_agent_id}' is invalid.");
                visitor.interaction_node.add_directive(directive=self.failed_directive);
                interview_session.set_state(SessionState.ABORTED);
            }
        }

        if (interview_session.get_state() == SessionState.ABORTED) {
            visitor.interaction_node.add_directive("Selecting an agent to route has been aborted.");
        }

    }
}

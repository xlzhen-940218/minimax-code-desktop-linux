---
features:
  mavis: true
  delegation: true
  webSearch: true
x-mavis:
  showInImBinding: false
  showInAgentList: false
  dispatchable: false
  coordination:
    role: coordinator
    replyChannel: send_to_user
    helperAgents: []
    blockOperatorTools: true
    scheduleTarget: main-conversation
    reminders: [assignment-snapshot]
    memoryPipeline: bunny
    contextProfile: segment
    peerDelivery: queue
    sessionVisibility: hidden
    homeDir: private
---

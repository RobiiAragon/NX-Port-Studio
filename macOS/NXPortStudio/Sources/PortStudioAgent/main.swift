// NX Port Studio's launchd agent (docs/nextendo-agent.md). launchd starts it on
// demand when a port or Studio looks up one of its Mach services.
import Foundation
import PortCore

let server = NextendoAgentServer.launchd()
server.resume()
dispatchMain()

#
# This file is part of the WsMan SOAP layer derived from GLPI Agent
# (https://github.com/glpi-project/glpi-agent), distributed under the terms of
# the GNU General Public License version 2 (GPL-2.0).
#
# NOTE: the GPL-2.0 is not compatible with the Apache-2.0 license used by
# centreon-plugins. Licensing must be clarified with the GLPI Agent copyright
# holders before this code is distributed as part of centreon-plugins.
#

package centreon::plugins::wsman::soap;

# Preload all WsMan SOAP node classes. Node classes are resolved by name while
# parsing responses, so they must all be loaded before the first request.

use strict;
use warnings;

use centreon::plugins::wsman::soap::Action;
use centreon::plugins::wsman::soap::Address;
use centreon::plugins::wsman::soap::Arguments;
use centreon::plugins::wsman::soap::Attribute;
use centreon::plugins::wsman::soap::Body;
use centreon::plugins::wsman::soap::Code;
use centreon::plugins::wsman::soap::Command;
use centreon::plugins::wsman::soap::CommandId;
use centreon::plugins::wsman::soap::CommandLine;
use centreon::plugins::wsman::soap::CommandResponse;
use centreon::plugins::wsman::soap::CommandState;
use centreon::plugins::wsman::soap::DataLocale;
use centreon::plugins::wsman::soap::Datetime;
use centreon::plugins::wsman::soap::DesiredStream;
use centreon::plugins::wsman::soap::EndOfSequence;
use centreon::plugins::wsman::soap::Enumerate;
use centreon::plugins::wsman::soap::EnumerateResponse;
use centreon::plugins::wsman::soap::EnumerationContext;
use centreon::plugins::wsman::soap::Envelope;
use centreon::plugins::wsman::soap::ExitCode;
use centreon::plugins::wsman::soap::Fault;
use centreon::plugins::wsman::soap::Filter;
use centreon::plugins::wsman::soap::Header;
use centreon::plugins::wsman::soap::Identify;
use centreon::plugins::wsman::soap::IdentifyResponse;
use centreon::plugins::wsman::soap::InputStreams;
use centreon::plugins::wsman::soap::Items;
use centreon::plugins::wsman::soap::Locale;
use centreon::plugins::wsman::soap::MaxElements;
use centreon::plugins::wsman::soap::MaxEnvelopeSize;
use centreon::plugins::wsman::soap::MessageID;
use centreon::plugins::wsman::soap::Namespace;
use centreon::plugins::wsman::soap::Node;
use centreon::plugins::wsman::soap::OperationID;
use centreon::plugins::wsman::soap::OperationTimeout;
use centreon::plugins::wsman::soap::OptimizeEnumeration;
use centreon::plugins::wsman::soap::Option;
use centreon::plugins::wsman::soap::OptionSet;
use centreon::plugins::wsman::soap::OutputStreams;
use centreon::plugins::wsman::soap::PartComponent;
use centreon::plugins::wsman::soap::Pull;
use centreon::plugins::wsman::soap::PullResponse;
use centreon::plugins::wsman::soap::Reason;
use centreon::plugins::wsman::soap::Receive;
use centreon::plugins::wsman::soap::ReceiveResponse;
use centreon::plugins::wsman::soap::ReferenceParameters;
use centreon::plugins::wsman::soap::RelatesTo;
use centreon::plugins::wsman::soap::ReplyTo;
use centreon::plugins::wsman::soap::ResourceCreated;
use centreon::plugins::wsman::soap::ResourceURI;
use centreon::plugins::wsman::soap::Selector;
use centreon::plugins::wsman::soap::SelectorSet;
use centreon::plugins::wsman::soap::SequenceId;
use centreon::plugins::wsman::soap::SessionId;
use centreon::plugins::wsman::soap::Shell;
use centreon::plugins::wsman::soap::Signal;
use centreon::plugins::wsman::soap::Stream;
use centreon::plugins::wsman::soap::Text;
use centreon::plugins::wsman::soap::To;
use centreon::plugins::wsman::soap::Value;

1;

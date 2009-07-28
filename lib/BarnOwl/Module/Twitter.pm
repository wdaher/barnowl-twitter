use warnings;
use strict;

=head1 NAME

BarnOwl::Module::Twitter

=head1 DESCRIPTION

Post outgoing zephyrs from -c $USER -i status -O TWITTER to Twitter

=cut

package BarnOwl::Module::Twitter;

our $VERSION = 0.1;

use Net::Twitter;
use JSON;

use BarnOwl;
use BarnOwl::Hooks;
use BarnOwl::Message::Twitter;
use HTML::Entities;

our $twitter;
my $user     = BarnOwl::zephyr_getsender();
my ($class)  = ($user =~ /(^[^@]+)/);
my $instance = "status";
my $opcode   = "twitter";
my $use_reply_to = 0;

sub fail {
    my $msg = shift;
    undef $twitter;
    BarnOwl::admin_message('Twitter Error', $msg);
    die("Twitter Error: $msg\n");
}

if($Net::Twitter::VERSION >= 2.06) {
    $use_reply_to = 1;
}

my $desc = <<'END_DESC';
BarnOwl::Module::Twitter will watch for authentic zephyrs to
-c $twitter:class -i $twitter:instance -O $twitter:opcode
from your sender and mirror them to Twitter.

A value of '*' in any of these fields acts a wildcard, accepting
messages with any value of that field.
END_DESC
BarnOwl::new_variable_string(
    'twitter:class',
    {
        default     => $class,
        summary     => 'Class to watch for Twitter messages',
        description => $desc
    }
);
BarnOwl::new_variable_string(
    'twitter:instance',
    {
        default => $instance,
        summary => 'Instance on twitter:class to watch for Twitter messages.',
        description => $desc
    }
);
BarnOwl::new_variable_string(
    'twitter:opcode',
    {
        default => $opcode,
        summary => 'Opcode for zephyrs that will be sent as twitter updates',
        description => $desc
    }
);

BarnOwl::new_variable_bool(
    'twitter:poll',
    {
        default => 1,
        summary => 'Poll Twitter for incoming messages',
        description => "If set, will poll Twitter every minute for normal updates,\n"
        . 'and every two minutes for direct message'
     }
 );

my $conffile = BarnOwl::get_config_dir() . "/twitter";
open(my $fh, "<", "$conffile") || fail("Unable to read $conffile");
my $cfg = do {local $/; <$fh>};
close($fh);
eval {
    $cfg = from_json($cfg);
};
if($@) {
    fail("Unable to parse ~/.owl/twitter: $@");
}

my $twitter_args = { username   => $cfg->{user} || $user,
                     password   => $cfg->{password},
                     source     => 'barnowl', 
                   };
if (defined $cfg->{service}) {
    my $service = $cfg->{service};
    $twitter_args->{apiurl} = $service;
    my $apihost = $service;
    $apihost =~ s/^\s*http:\/\///;
    $apihost =~ s/\/.*$//;
    $apihost .= ':80' unless $apihost =~ /:\d+$/;
    $twitter_args->{apihost} = $cfg->{apihost} || $apihost;
    my $apirealm = "Laconica API";
    $twitter_args->{apirealm} = $cfg->{apirealm} || $apirealm;
}

$twitter  = Net::Twitter->new(%$twitter_args);

if(!defined($twitter->verify_credentials())) {
    fail("Invalid twitter credentials");
}

our $last_poll        = 0;
our $last_direct_poll = 0;
our $last_id          = undef;
our $last_direct      = undef;

unless(defined($last_id)) {
    eval {
        $last_id = $twitter->friends_timeline({count => 1})->[0]{id};
    };
    $last_id = 0 unless defined($last_id);
}

unless(defined($last_direct)) {
    eval {
        $last_direct = $twitter->direct_messages()->[0]{id};
    };
    $last_direct = 0 unless defined($last_direct);
}

eval {
    $twitter->{ua}->timeout(1);
};

sub match {
    my $val = shift;
    my $pat = shift;
    return $pat eq "*" || ($val eq $pat);
}

sub handle_message {
    my $m = shift;
    ($class, $instance, $opcode) = map{BarnOwl::getvar("twitter:$_")} qw(class instance opcode);
    if($m->sender eq $user
       && match($m->class, $class)
       && match($m->instance, $instance)
       && match($m->opcode, $opcode)
       && $m->auth eq 'YES') {
        twitter($m->body);
    }
}

sub poll_messages {
    poll_twitter();
    poll_direct();
}

sub twitter_error {
    my $ratelimit = $twitter->rate_limit_status;
    unless(defined($ratelimit) && ref($ratelimit) eq 'HASH') {
        # Twitter's just sucking, sleep for 5 minutes
        $last_direct_poll = $last_poll = time + 60*5;
        # die("Twitter seems to be having problems.\n");
        return;
    }
    if(exists($ratelimit->{remaining_hits})
       && $ratelimit->{remaining_hits} <= 0) {
        $last_direct_poll = $last_poll = $ratelimit->{reset_time_in_seconds};
        die("Twitter: ratelimited until " . $ratelimit->{reset_time} . "\n");
    } elsif(exists($ratelimit->{error})) {
        die("Twitter: ". $ratelimit->{error} . "\n");
        $last_direct_poll = $last_poll = time + 60*20;
    }
}

## TODO: Make this more lenient?
sub is_source_barnowl {
    my $source = shift;
    return $source eq '<a href="http://barnowl.mit.edu">BarnOwl</a>';
}

sub poll_twitter {
    return unless ( time - $last_poll ) >= 60;
    $last_poll = time;
    return unless BarnOwl::getvar('twitter:poll') eq 'on';

    my $timeline = $twitter->friends_timeline( { since_id => $last_id } );
    unless(defined($timeline) && ref($timeline) eq 'ARRAY') {
        twitter_error();
        return;
    };
    if ( scalar @$timeline ) {
        for my $tweet ( reverse @$timeline ) {
            if ( $tweet->{id} <= $last_id ) {
                next;
            }
            my $msg = BarnOwl::Message->new(
                type      => 'Twitter',
                sender    => $tweet->{user}{screen_name},
                recipient => $cfg->{user} || $user,
                direction => 'in',
                source    => decode_entities($tweet->{source}),
                location  => decode_entities($tweet->{user}{location}||""),
                body      => decode_entities($tweet->{text}),
                status_id => $tweet->{id},
                service   => $cfg->{service},
               );
            BarnOwl::queue_message($msg);

	    # Mirror tweets sent from other clients to our class of choice
	    if ( $tweet->{user}{screen_name} eq $cfg->{user} && !is_source_barnowl($msg->source) ) {
		## TODO: Use BarnOwl variables for these
		my $class = "wdaher";
		my $instance = "status";
		my $opcode = "from-twitter";
		## TODO: If the opcode filter were '*', would this
		## cause a horrible infinite loop of zephyr/twitter
		## unpleasantness? Potentially. You probably want to
		## investigate this.
		BarnOwl::zephyr_zwrite("zwrite -c $class -i $instance -O $opcode", $msg->body);
	    }
        }
        $last_id = $timeline->[0]{id};
    } else {
        # BarnOwl::message("No new tweets...");
    }
}

sub poll_direct {
    return unless ( time - $last_direct_poll) >= 120;
    $last_direct_poll = time;
    return unless BarnOwl::getvar('twitter:poll') eq 'on';

    my $direct = $twitter->direct_messages( { since_id => $last_direct } );
    unless(defined($direct) && ref($direct) eq 'ARRAY') {
        twitter_error();
        return;
    };
    if ( scalar @$direct ) {
        for my $tweet ( reverse @$direct ) {
            if ( $tweet->{id} <= $last_direct ) {
                next;
            }
            my $msg = BarnOwl::Message->new(
                type      => 'Twitter',
                sender    => $tweet->{sender}{screen_name},
                recipient => $cfg->{user} || $user,
                direction => 'in',
                location  => decode_entities($tweet->{sender}{location}||""),
                body      => decode_entities($tweet->{text}),
                isprivate => 'true',
                service   => $cfg->{service},
               );
            BarnOwl::queue_message($msg);
        }
        $last_direct = $direct->[0]{id};
    } else {
        # BarnOwl::message("No new tweets...");
    }
}

sub twitter {
    my $msg = shift;
    my $reply_to = shift;

    if($msg =~ m{\Ad\s+([^\s])+(.*)}sm) {
        twitter_direct($1, $2);
    } elsif(defined $twitter) {
        if($use_reply_to && defined($reply_to)) {
            $twitter->update({
                status => $msg,
                in_reply_to_status_id => $reply_to
               });
        } else {
            $twitter->update($msg);
        }
    }
}

sub twitter_direct {
    my $who = shift;
    my $msg = shift;
    if(defined $twitter) {
        $twitter->new_direct_message({
            user => $who,
            text => $msg
           });
        if(BarnOwl::getvar("displayoutgoing") eq 'on') {
            my $tweet = BarnOwl::Message->new(
                type      => 'Twitter',
                sender    => $cfg->{user} || $user,
                recipient => $who, 
                direction => 'out',
                body      => $msg,
                isprivate => 'true',
                service   => $cfg->{service},
               );
            BarnOwl::queue_message($tweet);
        }
    }
}

sub twitter_atreply {
    my $to  = shift;
    my $id  = shift;
    my $msg = shift;
    if(defined($id)) {
        twitter("@".$to." ".$msg, $id);
    } else {
        twitter("@".$to." ".$msg);
    }
}

BarnOwl::new_command(twitter => \&cmd_twitter, {
    summary     => 'Update Twitter from BarnOwl',
    usage       => 'twitter [message]',
    description => 'Update Twitter. If MESSAGE is provided, use it as your status.'
    . "\nOtherwise, prompt for a status message to use."
   });

BarnOwl::new_command('twitter-direct' => \&cmd_twitter_direct, {
    summary     => 'Send a Twitter direct message',
    usage       => 'twitter-direct USER',
    description => 'Send a Twitter Direct Message to USER'
   });

BarnOwl::new_command( 'twitter-atreply' => sub { cmd_twitter_atreply(@_); },
    {
    summary     => 'Send a Twitter @ message',
    usage       => 'twitter-atreply USER',
    description => 'Send a Twitter @reply Message to USER'
    }
);


sub cmd_twitter {
    my $cmd = shift;
    if(@_) {
        my $status = join(" ", @_);
        twitter($status);
    } else {
      BarnOwl::start_edit_win('What are you doing?', \&twitter);
    }
}

sub cmd_twitter_direct {
    my $cmd = shift;
    my $user = shift;
    die("Usage: $cmd USER\n") unless $user;
    BarnOwl::start_edit_win("$cmd $user", sub{twitter_direct($user, shift)});
}

sub cmd_twitter_atreply {
    my $cmd  = shift;
    my $user = shift || die("Usage: $cmd USER [In-Reply-To ID]\n");
    my $id   = shift;
    BarnOwl::start_edit_win("Reply to \@" . $user, sub { twitter_atreply($user, $id, shift) });
}

eval {
    $BarnOwl::Hooks::receiveMessage->add("BarnOwl::Module::Twitter::handle_message");
    $BarnOwl::Hooks::mainLoop->add("BarnOwl::Module::Twitter::poll_messages");
};
if($@) {
    $BarnOwl::Hooks::receiveMessage->add(\&handle_message);
    $BarnOwl::Hooks::mainLoop->add(\&poll_messages);
}

BarnOwl::filter(qw{twitter type ^twitter$});

1;

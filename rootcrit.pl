#!/usr/bin/env perl
use Mojolicious::Lite;

use IO::Async::Loop;
use Net::Async::CassandraCQL;
use Protocol::CassandraCQL qw( CONSISTENCY_QUORUM );

use DateTime;

use Cwd;
use File::Slurp;
my $cwd = getcwd;
my $config_filename = 'rootcrit.conf';
my $config_filepath = File::Spec->catfile($cwd, $config_filename);
my $config_text = read_file($config_filepath);
my $config = eval $config_text;

my $cassandra_host = $config->{cassandra_host};
my $facility = $config->{facility};
my $sensor = $config->{sensor};
my $recipient = $config->{motion_gpg_public};

say "Connecting to Cassandra host at $cassandra_host";
my $cass_loop = IO::Async::Loop->new;
my $cass = Net::Async::CassandraCQL->new(
    host => "$cassandra_host",
    keyspace => "rootcrit",
    default_consistency => CONSISTENCY_QUORUM,
    cql_version => 2,
);
$cass_loop->add( $cass );
my $result = $cass->connect->get;

my $verbose_debug = 2;
my $no_debug = 0;
my $debug_level = $no_debug;

plugin 'Authentication' => {
  'autoload_user' => 1,
  'session_key' => 'rootcritbro', # CHANGE ME
  'load_user' => sub {
    my ($c, $uid) = @_;
    my $config = $c->app->plugin('Config');
    my $user = $config->{username};
    return $user;
  },
  'validate_user' => sub {
    my ($c, $username, $password, $extradata) = @_;
    my $uid = 0;
    my $config = $c->app->plugin('Config');
    my $good_username = $config->{username} // 'insecure';
    my $good_password = $config->{password} // 'password';
    if ($username eq $good_username && $password eq $good_password) {
       $uid = 1;
    }
    return $uid;
  },
  'current_user_fn' => 'user', # compatibility with old code
};

# Documentation browser under "/perldoc"
plugin 'PODRenderer';

plugin 'Config';
 
any '/login' => sub {
    my $c = shift;

    my $u = $c->req->param('username');
    my $p = $c->req->param('password');
 
    if ($c->authenticate($u,$p)) {
      $c->redirect_to('/');
    }
    else {
      $c->render(
        template => 'login',
        message => 'Failed to login'
      );
    }
};

get '/logout' => (authenticated => 1) => sub {
    my $self = shift;
 
    $self->logout();
    $self->render( template => 'login', message => 'Logged out...' );
};

get '/' => sub {
  my $c = shift;
  if (!$c->is_user_authenticated) {
    $c->render(
      template => 'login',
      message => 'You were not authenticated',
    );
  }
  else {
    $c->render(
      template  => 'index',
      uptime    => 'Loading',
      who       => 'Loading',
      top       => 'Loading',
      motion    => 'Loading',
    );
  }
};

get '/info/uptime' => (authenticated => 1) => sub {
    my $c = shift;
    my $uptime = qx(uptime);
    $c->render(
      json => $uptime,
    );
};

get '/info/who' => (authenticated => 1) => sub {
    my $c = shift;
    my $who = qx(who);
    $c->render(
      json => $who,
    );
};

get '/info/top' => (authenticated => 1) => sub {
    my $c = shift;
    my $top = qx(top -n 1 -b);
    $c->render(
      json => $top,
    );
};

sub start_motion {
    my ($config_path) = @_;
    # Add it to the payload string
    my $motion_command = 'motion';
    if ($config_path) {
        $motion_command .= " -c $config_path";
    }
    # Open motion via IPC::Open3
    # Get the pid and return it
    use IPC::Open3;
    my $pid = open3(my $writer, my $reader, my $errors, $motion_command);
    return $pid;
}

sub create_motion_lock {
# Actually, what the heck are we getting here?
# Can I refer to this via $c?
    my ($pid) = @_;
    my $lockfile_created = 0;
    my $lockdir = '/tmp/rootcrit';
    my $filename = "motion.$pid.lock";
    use Try::Tiny;
    $lockfile_created = try {
        my $is_success = 0;
        # Alright, get the pattern for the lockfile
        # Get the lockfile directory
        opendir(my $handle, $lockdir) or die 'can not open dir';
        # Insert the pid into the lockfile as well
        open(my $fh, '>', $lockdir . '/' . $filename) or die "can not open '$filename'";
        print $fh "$pid";
        return $is_success;
    }
    catch {
        warn "ERROR";
        # Tell me about it
        my $err = $_;
        warn "$err";
    };
    return $lockfile_created;
}

sub remove_motion_lock {
    my $lockdir = '/tmp/rootcrit';
    unlink glob "'$lockdir/motion.*.lock'";
}

sub is_motion_running {
    my $lock_found = 0;
    my $lockdir = '/tmp/rootcrit';
    use Try::Tiny;
    $lock_found = try {
        if (!-d $lockdir) {
            mkdir $lockdir;
            $lock_found = 0;
        }
        else {
            opendir(my $handle, $lockdir) or die 'can not open dir';
            for my $entry (readdir $handle) {
                if ($entry =~ m/motion\.\d+\.lock/) {
                    $lock_found = 1;
                    last;
                }
            }
        }
        return $lock_found;
    } catch {
        my $err = $_;
        warn "$err";
    };
    return $lock_found;
}

get '/info/motion/status' => (authenticated => 1) => sub {
    my $c = shift;
    my $status = is_motion_running();
    $c->render(
        json => {
        status => $status,
        external_host => $c->app->plugin('Config')->{motion_external_host},
    }
    );
};

get '/shutdown' => (authenticated => 1) => sub {
  my $c = shift;
  qx(shutdown -h now);
  $c->render(template => 'shutdown');
};

get '/motion/start' => (authenticated => 1) => sub {
    my $c = shift;
# check for a pid lock file in /tmp
# if no lock found...
    my $running = 1;
    my $motion_status = is_motion_running();
    if ($motion_status == $running) {
        # Do nothing I guess. 
        # Space reserved for better ideas.
    }
    else {
        # create a pid lock file in /tmp
        # should look like /tmp/rootcrit/motion.pid
        # Get the config file path, if given
        my $config = $c->app->plugin('Config');
        my $config_path = $config->{motion_config_path};
        my $motion_pid = start_motion($config_path);
        create_motion_lock($motion_pid);
    }
    $c->render(
        template    => 'index',
        uptime      => 'Loading',
        who         => 'Loading',
        top         => 'Loading',
        motion      => 'Loading',
    );
};

get '/motion/stop' => (authenticated => 1) => sub {
    my $c = shift;
# check for a pid lock file in /tmp
# if there's a pid lock file
    # get the pid
    # kill the pid
    # delete the pid lock file
    system 'killall motion';
    remove_motion_lock();
    $c->render(
        template => 'index',
        uptime    => 'Loading',
        who       => 'Loading',
        top       => 'Loading',
        motion    => 'Loading',
    );
};

get '/incidents' => (authenticated => 1) => sub {
    my $c = shift;
    my $last_48_hours = DateTime->now();
    $last_48_hours->subtract(hours => 72);
    my $recent_incidents = $last_48_hours->strftime('%Y-%m-%d %R');
    my $facility_name = $c->app->plugin('Config')->{facility};
    # I need to be able to select a start and end time
    my $query = qq{
        SELECT
            dateof(incident_id) AS timestamp,
            incident_id, facility, sensor, sensor_filename 
        FROM incident_by_facility WHERE facility = '$facility_name' ORDER BY incident_id DESC;
    };
    my $consistency = CONSISTENCY_QUORUM;
    my %other_args = (
        page_size       => 3,
    );
    if ($c->session->{'paging_state'}) {
        $other_args{paging_state} = $c->session->{'paging_state'};
    }
    my (undef, $x) = $cass->query($query, $consistency, %other_args)->get;
    $c->session('paging_state' => $x->paging_state);
    $c->render(
        json => {
            result => [$x->rows_hash],
        } 
    );
};

get '/incident/image/:incident_id' => (authenticated => 1) => sub {
    my ($c) = @_;
    my $incident_id = $c->stash('incident_id');
    warn "selected incident id $incident_id";
    # Get the incident's image data
    my $facility_name = $c->app->plugin('Config')->{facility};
    my $select = $cass->prepare("SELECT sensor_filename, image FROM incident_by_facility WHERE facility = '$facility_name' AND incident_id = $incident_id;");
    my (undef, $x) = $select->get->execute([])->get;
    my @rows = $x->rows_hash;
    my $image_blob = $rows[0]->{image};
    $c->res->headers->content_type('application/pgp-encryption');
    $c->render(
        data => $image_blob,
    );
};

# Index page
    # Collect some system information for the user
    # Show the motion status
    # Offer to switch it on and off
    # Show the shutdown switch
    # Offer a gallery of the currently recorded pictures
# Accept a shutdown command
    # Create a calendar event for remote shutdown event
    # Shut down the system properly
    
app->start;
__DATA__

@@ index.html.ep
    % content_for css => begin
        div.rootcrit-top pre {
            height: 400px;
            overflow: auto;
        }
        .top-level-spacing {
            margin-bottom: 50px;
        }
        div.rootcrit-motion span.rootcrit-motion-enable {
            display: hidden;
        }

        div.rootcrit-motion span.rootcrit-motion-disable {
            display: hidden;
        }

        textarea.rootcrit-motion-encryption-key {
            height: 150px;
            width: 100%;
        }
    % end
    % content_for javascript => begin 
        $(document).ready(function () {
            require(['openpgp.min'], function (openpgp) {
                // We need a way to signal if you currently uploaded a private key
                window.rootcrit = {};
                window.rootcrit.privateKey = '';

                // You need to be able to name the private key and import it as ascii or a file
                // Prompt for a password as well.
                // The private key should be globally accessible
                // We then load the incident data as a plain blob.
                // Decrypt all the blobs.
                // Display the image as a png in the browser.
                var load_incidents_updater = function () {
                    console.log("Loading incidents!");
                    $.ajax({
                        url: '/incidents',
                    }).then(function (incidents) {
                        console.log("Here they are");
                        console.log(incidents);
                        var result = incidents.result;

                        var privateKey = openpgp.key.readArmored(window.rootcrit.privateKey).keys[0];
                        console.log(window.rootcrit.decryptionKey);
                        if (typeof window.rootcrit.decryptionKey === 'undefined') {
                            window.rootcrit.decryptionKey = prompt("Enter decryption passphrase");
                        }
                        privateKey.decrypt(window.rootcrit.decryptionKey);
                        var ii = 0;
                        var decrypt_incident = function (ii) {
                            var oReq = new XMLHttpRequest();
                            oReq.open("GET", '/incident/image/' + result[ii].incident_id, true);
                            oReq.responseType = "arraybuffer";

                            oReq.onload = function (oEvent) {
                              var arrayBuffer = oReq.response; // Note: not oReq.responseText
                              if (arrayBuffer) {
                                var byteArray = new Uint8Array(arrayBuffer);
                                var options = {
                                    message: openpgp.message.read(byteArray),
                                    privateKey: privateKey,
                                    format: 'binary'
                                };
                                openpgp.decrypt(options).then(function (plaintext) {
                                    $('div.rootcrit-motion-incident-list').prepend(
                                        "<img src='data:image/png;base64," + btoa(String.fromCharCode.apply(null, plaintext.data)) + "'><br />"
                                    );
                                    // Cassandra TimeUUIDs are 'epoch' and not 'unixepoch'. Date() needs a multiplication.
                                    var dt = new Date(result[ii].timestamp * 1000);
                                    $('div.rootcrit-motion-incident-list').prepend("<a class='col-xs-12' href='/incident/" + result[ii].incident_id + "'>" +
                                        "Incident at " + dt + " " +
                                        "</a>");
                                    $('div.rootcrit-motion-incident-list').prepend("<a class='col-xs-12' href='/incident/image/" + result[ii].incident_id + "'>" +
                                        "Download incident data" +
                                        "</a>");
                                    ii++;
                                    decrypt_incident(ii);
                                });
                              }
                            };

                            oReq.send(null);
                        };
                        decrypt_incident(ii);
                    });
                };

                $('div.rootcrit-motion-encryption button').on('click', function (e) {
                    // Strip leading spaces here, please!
                    // Textarea should be completely empty
                    window.rootcrit.privateKey = $('div.rootcrit-motion-encryption textarea').val();
                    console.log(window.rootcrit.privateKey);
                    load_incidents_updater();
                });
            });
            window.motion = {};
            var debug = 0;
            var host_system_information = ['uptime', 'who', 'top'];
            var update_function = function () {
                if (debug) {
                  console.log(host_system_information.length);
                }
                for (var i = 0; i < host_system_information.length; i++) {
                  var host_command = host_system_information[i];
                  var host_update_container = 'div.rootcrit-' + host_command + ' .update-container';
                  if (debug) {
                    console.log('host system information ' + i);
                    console.log(host_update_container);
                    console.log('Starting ajax');
                  }
                  var update_ajax = function (host_command, host_update_container) {
                    $.ajax({
                      url: '/info/' + host_command,
                      success: function (return_data) {
                          if (debug) {
                            console.log('host_command ' + host_command);
                            console.log('host_update_container ' + host_update_container);
                          }
                          $(host_update_container).text(return_data);
                      },
                      error: function (jqXHR, textStatus, errorThrown) {
                          $(host_update_container).text(textStatus + ' ' + errorThrown);
                      }
                    });
                  };
                  update_ajax(host_command, host_update_container);
                }
            };
            update_function();
            var update_timer = setInterval(update_function, 2000);
            var info_updates_active = 1;
            $('button#rootcrit-toggle-info-update').click(function () {
                if (info_updates_active) {
                    clearInterval(update_timer); 
                    info_updates_active = 0;
                    $('button#rootcrit-toggle-info-update').text('Enable updates');
                }
                else {
                    update_timer = setInterval(update_function, 2000);
                    info_updates_active = 1;
                    $('button#rootcrit-toggle-info-update').text('Disable updates');
                }
            });

            $('div.rootcrit-motion button.rootcrit-motion-button').prop('disabled', true);
            var motion_status_function  = function () {
                if (debug) {
                    console.log('Inside motion function');
                }
                var xhr = $.ajax({
                    url: '/info/motion/status',
                }).then(
                    function (motionInfoJSON) {
                        var motionStatus = motionInfoJSON['status'];
                        $('div.rootcrit-motion button.rootcrit-motion-button').prop('disabled', false);
                        if (debug) { console.log(motionStatus); }
                        var enabled = 1;
                        if (motionStatus == enabled) {
                            $('div.rootcrit-motion span.rootcrit-motion-enable').hide();
                            $('div.rootcrit-motion span.rootcrit-motion-disable').show();
                            $('div.rootcrit-motion span.rootcrit-motion-status').text('ON');
                            window.motion.action = '/motion/stop';
                
                            $('div.rootcrit-motion div.rootcrit-motion-stream-container')
                                .html('<img src="' + motionInfoJSON['external_host'] + '" onerror="this.style.display=\'none\';this.style.height=0">')
                                .css('height', 300) // 300 px, height of the mjpg roughly
                                .css('margin-top', 25);
                            $('div.rootcrit-motion div.rootcrit-motion-stream-container img').error(function (e) {
                                $(this).hide();
                            });
                        }
                        else {
                            $('div.rootcrit-motion span.rootcrit-motion-disable').hide();
                            $('div.rootcrit-motion span.rootcrit-motion-enable').show();
                            $('div.rootcrit-motion span.rootcrit-motion-status').text('OFF');
                $('div.rootcrit-motion div.rootcrit-motion-stream-container img').remove();
                $('div.rootcrit-motion div.rootcrit-motion-stream-container')
                .css('height', 0)
                .css('margin-top', 25);
                            window.motion.action = '/motion/start';
                        }
                    }, function (xhr, httpStatus, error) {
                        $('div.rootcrit-motion button.rootcrit-motion-button').disable();
                        if (debug) {
                            console.log(httpStatus);
                            console.log(error);
                        }
                        $('div.rootcrit-motion span.rootcrit-motion-status').text('ERROR!');
                    }
                );
                // basically we are going to check '/info/motion/status' and
                // we will get a json response  telling us if it's up or down
                // we take that status and toggle the button on/off based on
                // that result
            };
            motion_status_function();
            var motion_status_timer = setInterval(motion_status_function, 5000); // 2 seconds in ms
            // and put a timer here for the motion status function
            $('div.rootcrit-motion button.rootcrit-motion-button').click(function () {
                $.ajax({
                    url: window.motion.action
                });
                motion_status_function();
            });

            // we can embed the mjpeg stream from motion here if we have it
            // chrome and safari should refresh automatically...allegedly

            // we want a gallery of the backlogged motion events
            // but I am not sure what the interface should look like right now.
            // obviously we prioritize new events over old events. but if you are
            // looking at a single event, we don't want to change focus or make it harder
            // to look back in time.

            // I should look into some real time events. It might behoove me to a reddit front-page like
            // setup where it's a list on its own page that needs to be refreshed manually
            // individual events should have their own page and should be linkable based on UUID
            $('div#shutdown-button > form').click(function (e) {
                if (confirm('Are you sure?')) {
                    return;
                }
                e.preventDefault();
            });
        });
    % end
% layout 'default';
% title 'Rootcrit';
<div class='panel'>
  <div class='col-xs-12 col-sm-6 col-sm-offset-3 top-level-spacing'>
    <h1>Welcome to Rootcrit</h1>
  </div>
  <div id='shutdown-button' class='col-xs-12 col-sm-6 col-sm-offset-3 top-level-spacing'>
    <form action="/shutdown">
      <button class='btn btn-primary col-xs-12'>Shutdown the system</button>
    </form>
  </div>
  <div class="col-xs-12 col-sm-6 col-sm-offset-3 top-level-spacing">
    <button class="btn btn-primary col-xs-12" type="button" data-toggle="collapse" data-target="#rootcrit-system-info" aria-expanded="false" aria-controls="rootcrit-system-info">
        Show/hide system info 
    </button>
    <div id="rootcrit-system-info" class="collapse">
        <button id="rootcrit-toggle-info-update" class="btn btn-primary col-xs-12" type="button">
           Disable updates
        </button>
        <div class='rootcrit-uptime col-xs-12'>
          <h2>uptime</h2>
          <pre class="update-container">
    <  %= $uptime %>
          </pre>
        </div>
        <div class='rootcrit-who col-xs-12'>
          <h2>who</h2>
          <pre class="update-container">
    <  %= $who %>
          </pre>
        </div>
        <div class='rootcrit-top col-xs-12'>
          <h2>top</h2>
          <pre class="update-container">
    <  %= $top %>
          </pre>
        </div>
        <button class="btn btn-primary col-xs-12" type="button" data-toggle="collapse" data-target="#rootcrit-system-info" aria-expanded="false" aria-controls="rootcrit-system-info">
            Show/hide system info
        </button>
    </div>
  </div>
  <div class='rootcrit-motion col-xs-12 col-sm-6 col-sm-offset-3 top-level-spacing'>
    <h2>motion</h2>
    <h3>Status: <span class='rootcrit-motion-status'>Unknown</span></h3>
    <button class='rootcrit-motion-button btn btn-primary col-xs-12'>
        <span class='rootcrit-motion-disable' style='display: hidden'>Disable</span>
        <span class='rootcrit-motion-enable' style='display: hidden'>Enable</span>
        <span class='rootcrit-motion-label'>Motion</span>
    </button>
    <div class="rootcrit-motion-stream-container">
    </div>
  </div>
  <div class='rootcrit-motion-encryption col-xs-12 col-sm-6 col-sm-offset-3 top-level-spacing'>
    <h2>ASCII Armored Private Key</h2>
    <textarea class='rootcrit-motion-encryption-key'>
    </textarea>
    <button class='rootcrit-motion-load-privatekey btn btn-primary col-xs-12'>
        Load Some Incidents
    </button>
  </div>
  <div class='rootcrit-motion-incidents col-xs-12 col-sm-6 col-sm-offset-3 top-level-spacing'>
    <h2>Select Time Range</h2>
    <div class="rootcrit-motion-incident-time-range">
        <p>Unimplemented</p>
        <p>Start Date:</p>
        <p>Start Time:</p>
        <p>End Date:</p>
        <p>End Time:</p>
    </div>
    <h2>Incidents</h2>
    <div class="rootcrit-motion-incident-list">
    </div>
  </div>
  <div class='col-xs-12 col-sm-6 col-sm-offset-3 top-level-spacing'>
    <a href="/logout">
      <button class='btn btn-primary col-xs-12'>Logout</button>
    </a>
  </div>
</div>

@@ login.html.ep
% layout 'default';
% title 'Rootcrit - Login';
<div class="panel">
    <div class="col-xs-12 col-sm-4 col-sm-offset-4">
        <h2><%= $message %></h2>
    </div>
    <div class="col-xs-12 col-sm-4 col-sm-offset-4">
        <form method="POST" action="/login">
            <div class="form-group">
                <label for="username">Username</label>
                <input type="text" name="username"></input>
            </div>
            <div class="form-group">
                <label for="password">Password</label>
                <input type="password" name="password"></input>
            </div>
            <button type="submit" class="btn btn-default">Submit</button>
        </form>
    </div>
</div>

@@ shutdown.html.ep
% layout 'default';
% title 'Shutting Down';
<h1>Thanks for playing</h1>

@@ not_found.html.ep
% layout 'default';
% title '404 Not Found';

<h1> 404 Not Found </h1>
<a href="/">Return to Site</a>

@@ layouts/default.html.ep
<!DOCTYPE html>
<html>
  <head>
    <title><%= title %></title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <script src="http://code.jquery.com/jquery-2.1.4.min.js"></script>

    <!-- Latest compiled and minified CSS -->
    <link rel="stylesheet" href="https://maxcdn.bootstrapcdn.com/bootstrap/3.3.5/css/bootstrap.min.css" integrity="sha512-dTfge/zgoMYpP7QbHy4gWMEGsbsdZeCXz7irItjcC3sPUFtf0kuFbDz/ixG7ArTxmDjLXDmezHubeNikyKGVyQ==" crossorigin="anonymous">

    <!-- Optional theme -->
    <link rel="stylesheet" href="https://maxcdn.bootstrapcdn.com/bootstrap/3.3.5/css/bootstrap-theme.min.css" integrity="sha384-aUGj/X2zp5rLCbBxumKTCw2Z50WgIr1vs/PFN4praOTvYXWlVyh2UtNUU0KAUhAX" crossorigin="anonymous">
    <!-- Custom CSS -->
    <style>
        <%== content 'css' %>
    </style>

    <!-- Latest compiled and minified JavaScript -->
    <script src="https://maxcdn.bootstrapcdn.com/bootstrap/3.3.5/js/bootstrap.min.js" integrity="sha512-K1qjQ+NcF2TYO/eI3M6v8EiNYZfA95pQumfvcVrTHtwQVDG+aHRqLi/ETn2uB+1JqwYqVG3LIvdm9lj6imS/pQ==" crossorigin="anonymous"></script>
    <script src="/require.js"></script>
    <!-- Custom Javascript -->
    <script>
        <%== content 'javascript' %>
    </script>
  </head>
  <body><%= content %></body>
</html>

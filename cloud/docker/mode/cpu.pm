#
# Copyright 2015 Centreon (http://www.centreon.com/)
#
# Centreon is a full-fledged industry-strength solution that meets
# the needs in IT infrastructure and application monitoring for
# service performance.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

package cloud::docker::mode::cpu;

use base qw(centreon::plugins::mode);

use strict;
use warnings;
use centreon::plugins::http;
use centreon::plugins::statefile;
use JSON;

sub new {
    my ($class, %options) = @_;
    my $self = $class->SUPER::new(package => __PACKAGE__, %options);
    bless $self, $class;

    $self->{version} = '1.0';
    $options{options}->add_options(arguments =>
        {
            "hostname:s"        => { name => 'hostname' },
            "port:s"            => { name => 'port', default => '2376'},
            "proto:s"           => { name => 'proto', default => 'https' },
            "urlpath:s"         => { name => 'url_path', default => '/' },
            "name:s"            => { name => 'name' },
            "id:s"              => { name => 'id' },
            "warning:s"         => { name => 'warning' },
            "critical:s"        => { name => 'critical' },
            "credentials"       => { name => 'credentials' },
            "username:s"        => { name => 'username' },
            "password:s"        => { name => 'password' },
            "ssl:s"             => { name => 'ssl', },
            "cert-file:s"       => { name => 'cert_file' },
            "key-file:s"        => { name => 'key_file' },
            "cacert-file:s"     => { name => 'cacert_file' },
            "timeout:s"         => { name => 'timeout' },
        });

    $self->{statefile_value} = centreon::plugins::statefile->new(%options);
    $self->{http} = centreon::plugins::http->new(output => $self->{output});

    return $self;
}

sub check_options {
    my ($self, %options) = @_;
    $self->SUPER::init(%options);

    if ((defined($self->{option_results}->{name})) && (defined($self->{option_results}->{id}))) {
        $self->{output}->add_option_msg(short_msg => "Please set the name or id option");
        $self->{output}->option_exit();
    }

    if ((!defined($self->{option_results}->{name})) && (!defined($self->{option_results}->{id}))) {
        $self->{output}->add_option_msg(short_msg => "Please set the name or id option");
        $self->{output}->option_exit();
    }

    if (($self->{perfdata}->threshold_validate(label => 'warning', value => $self->{option_results}->{warning})) == 0) {
       $self->{output}->add_option_msg(short_msg => "Wrong warning threshold '" . $self->{option_results}->{warning} . "'.");
       $self->{output}->option_exit();
    }

    if (($self->{perfdata}->threshold_validate(label => 'critical', value => $self->{option_results}->{critical})) == 0) {
       $self->{output}->add_option_msg(short_msg => "Wrong critical threshold '" . $self->{option_results}->{critical} . "'.");
       $self->{output}->option_exit();
    }

    $self->{option_results}->{get_param} = [];
      push @{$self->{option_results}->{get_param}}, "stream=false";
    if (defined($self->{option_results}->{id})) {
        $self->{option_results}->{url_path} = "/containers/".$self->{option_results}->{id}."/stats";
    } elsif (defined($self->{option_results}->{name})) {
        $self->{option_results}->{url_path} = "/containers/".$self->{option_results}->{name}."/stats";
    }

    $self->{http}->set_options(%{$self->{option_results}});
    $self->{statefile_value}->check_options(%options);
}

sub run {
    my ($self, %options) = @_;

    if (defined($self->{option_results}->{id})) {
        $self->{statefile_value}->read(statefile => 'docker_' . $self->{option_results}->{id}  . '_' . $self->{http}->get_port() . '_' . $self->{mode});
    } elsif (defined($self->{option_results}->{name})) {
        $self->{statefile_value}->read(statefile => 'docker_' . $self->{option_results}->{name}  . '_' . $self->{http}->get_port() . '_' . $self->{mode});
    }

    my $jsoncontent = $self->{http}->request();

    my $json = JSON->new;

    my $webcontent;

    eval {
        $webcontent = $json->decode($jsoncontent);
    };

    if ($@) {
        $self->{output}->add_option_msg(short_msg => "Cannot decode json response");
        $self->{output}->option_exit();
    }

    my $cpu_totalusage = $webcontent->{cpu_stats}->{cpu_usage}->{total_usage};
    my $cpu_systemusage = $webcontent->{cpu_stats}->{system_cpu_usage};
    my @cpu_number = @{$webcontent->{cpu_stats}->{cpu_usage}->{percpu_usage}};

    my $new_datas = {};
    $new_datas->{cpu_totalusage} = $cpu_totalusage;
    $new_datas->{cpu_systemusage} = $cpu_systemusage;
    my $old_cpu_totalusage = $self->{statefile_value}->get(name => 'cpu_totalusage');
    my $old_cpu_systemusage = $self->{statefile_value}->get(name => 'cpu_systemusage');

    if ((!defined($old_cpu_totalusage)) || (!defined($old_cpu_systemusage))) {
        $self->{output}->output_add(severity => 'OK',
                                    short_msg => "Buffer creation...");
        $self->{statefile_value}->write(data => $new_datas);
        $self->{output}->display();
        $self->{output}->exit();
    }

    if ($new_datas->{cpu_totalusage} < $old_cpu_totalusage) {
        # We set 0. Has reboot.
        $old_cpu_totalusage = 0;
    }
    if ($new_datas->{cpu_systemusage} < $old_cpu_systemusage) {
        # We set 0. Has reboot.
        $old_cpu_systemusage = 0;
    }

    my $delta_totalusage = $cpu_totalusage - $old_cpu_totalusage;
    my $delta_systemusage = $cpu_systemusage - $old_cpu_systemusage;
    my $prct_cpu = (($delta_totalusage / $delta_systemusage) * scalar(@cpu_number)) * 100;

    my $exit = $self->{perfdata}->threshold_check(value => $prct_cpu, threshold => [ { label => 'critical', 'exit_litteral' => 'critical' }, { label => 'warning', exit_litteral => 'warning' } ]);

    $self->{output}->output_add(severity => $exit,
                                short_msg => sprintf("CPU Usage is %.2f%%", $prct_cpu));

    $self->{output}->perfdata_add(label => "cpu", unit => '%',
                                  value => $prct_cpu,
                                  warning => $self->{perfdata}->get_perfdata_for_output(label => 'warning'),
                                  critical => $self->{perfdata}->get_perfdata_for_output(label => 'critical'),
                                  min => 0,
                                  max => 100,
                                 );

    $self->{statefile_value}->write(data => $new_datas);

    $self->{output}->display();
    $self->{output}->exit();

}

1;

__END__

=head1 MODE

Check Container's CPU usage

=over 8

=item B<--hostname>

IP Addr/FQDN of Docker's API

=item B<--port>

Port used by Docker's API (Default: '2576')

=item B<--proto>

Specify https if needed (Default: 'https')

=item B<--urlpath>

Set path to get Docker's container information (Default: '/')

=item B<--id>

Specify one container's id

=item B<--name>

Specify one container's name

=item B<--warning>

Threshold warning in percent.

=item B<--critical>

Threshold critical in percent.

=item B<--credentials>

Specify this option if you access webpage over basic authentification

=item B<--username>

Specify username

=item B<--password>

Specify password

=item B<--ssl>

Specify SSL version (example : 'sslv3', 'tlsv1'...)

=item B<--cert-file>

Specify certificate to send to the webserver

=item B<--key-file>

Specify key to send to the webserver

=item B<--cacert-file>

Specify root certificate to send to the webserver

=item B<--timeout>

Threshold for HTTP timeout (Default: 3)

=back

=cut

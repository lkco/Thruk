package Thruk::BP::Utils;

use strict;
use warnings;
use Digest::MD5 qw(md5_hex);
use File::Temp qw/tempfile/;
use File::Copy qw/move/;
use Thruk::BP::Components::BP;

use Carp;
use Config::General;

=head1 NAME

Thruk::BP::Utils - Helper for the business process addon

=head1 DESCRIPTION

Helper for the business process addon

=head1 METHODS

=cut

##########################################################

=head2 load_bp_data

    load_bp_data($c, [$num], [$editmode])

editmode:
    - 0/undef:    no edit mode
    - 1:          only edit mode

load all or specific business process

=cut
sub load_bp_data {
    my($c, $num, $editmode) = @_;

    # make sure our folders exist
    my $base_folder = Thruk::BP::Utils::base_folder($c);
    Thruk::Utils::IO::mkdir_r($c->config->{'var_path'}.'/bp');
    Thruk::Utils::IO::mkdir_r($base_folder);

    my $bps   = [];
    my $pattern = '*.tbp';
    if($num) {
        return($bps) unless $num =~ m/^\d+$/mx;
        $pattern = $num.'.tbp';
    }
    my @files = glob($base_folder.'/'.$pattern);
    for my $file (@files) {
        my $bp = Thruk::BP::Components::BP->new($c, $file, undef, $editmode);
        push @{$bps}, $bp if $bp;
    }

    # sort by name
    @{$bps} = sort { $a->{'name'} cmp $b->{'name'} } @{$bps};

    return($bps);
}

##########################################################

=head2 next_free_bp_file

    next_free_bp_file($c)

return next free bp file

=cut
sub next_free_bp_file {
    my($c) = @_;
    my $num = 1;
    my $base_folder = Thruk::BP::Utils::base_folder($c);
    Thruk::Utils::IO::mkdir_r($c->config->{'var_path'}.'/bp');
    Thruk::Utils::IO::mkdir_r($base_folder);
    while(-e $base_folder.'/'.$num.'.tbp' || -e $c->config->{'var_path'}.'/bp/'.$num.'.tbp.edit') {
        $num++;
    }
    return($base_folder.'/'.$num.'.tbp', $num);
}

##########################################################

=head2 make_uniq_label

    make_uniq_label($c, $label, $bp_id)

returns new uniq label

=cut
sub make_uniq_label {
    my($c, $label, $bp_id) = @_;

    # gather names of all BPs and editBPs
    my $names = {};
    my @files = glob(Thruk::BP::Utils::base_folder($c).'/*.tbp '.$c->config->{'var_path'}.'/bp/*.tbp.edit');
    for my $file (@files) {
        next if $bp_id and $file =~ m#/$bp_id\.tbp(.edit|)$#mx;
        my $data = Thruk::Utils::IO::json_lock_retrieve($file);
        $names->{$data->{'name'}} = 1;
    }

    my $num = 2;
    my $testlabel = $label;
    while(defined $names->{$testlabel}) {
        $testlabel = $label.' '.$num++;
    }

    return $testlabel;
}

##########################################################

=head2 update_bp_status

    update_bp_status($c, $bps)

update status of all given business processes

=cut
sub update_bp_status {
    my($c, $bps) = @_;
    for my $bp (@{$bps}) {
        $bp->update_status($c);
    }
    return;
}

##########################################################

=head2 save_bp_objects

    save_bp_objects($c, $bps)

save business processes objects to object file

=cut
sub save_bp_objects {
    my($c, $bps) = @_;

    my $file = $c->config->{'Thruk::Plugin::BP'}->{'objects_save_file'};
    return(0, 'ok') unless $file;

    my($rc, $msg) = (0, 'reload ok');
    my $obj = {'hosts' => {}, 'services' => {}};
    for my $bp (@{$bps}) {
        my $data = $bp->get_objects_conf();
        merge_obj_hash($obj, $data);
    }

    my($fh, $filename) = tempfile();
    binmode($fh, ":encoding(UTF-8)");
    print $fh "# thruk: readonly\n\n";
    print $fh "# don't change, file is generated by thruk and will be overwritten.\n\n\n";
    for my $hostname (keys %{$obj->{'hosts'}}) {
        print $fh 'define host {', "\n";
        for my $attr (keys %{$obj->{'hosts'}->{$hostname}}) {
            print $fh ' ', $attr, ' ', $obj->{'hosts'}->{$hostname}->{$attr}, "\n";
        }
        print $fh "}\n";
    }
    for my $hostname (keys %{$obj->{'services'}}) {
        for my $description (keys %{$obj->{'services'}->{$hostname}}) {
            print $fh 'define service {', "\n";
            for my $attr (keys %{$obj->{'services'}->{$hostname}->{$description}}) {
                print $fh ' ', $attr, ' ', $obj->{'services'}->{$hostname}->{$description}->{$attr}, "\n"
            }
            print $fh "}\n";
        }
    }

    Thruk::Utils::IO::close($fh, $filename);

    my $new_hex = md5_hex($filename);
    my $old_hex = md5_hex($file);

    # check if something changed
    if($new_hex ne $old_hex) {
        if(!move($filename, $file)) {
            Thruk::Utils::set_message( $c, { style => 'fail_message', msg => 'move '.$filename.' to '.$file.' failed: '.$! });
            return $c->response->redirect($c->stash->{'url_prefix'}."cgi-bin/bp.cgi");
        }
        # and reload
        my $cmd = $c->config->{'Thruk::Plugin::BP'}->{'objects_reload_cmd'};
        if($cmd) {
            local $SIG{CHLD}='';
            local $ENV{REMOTE_USER}=$c->stash->{'remote_user'};
            my $out = `$cmd 2>&1`;
            ($rc, $msg) = ($?, $out);
            Thruk::Utils::wait_after_reload($c);
        }
        elsif($c->config->{'Thruk::Plugin::BP'}->{'result_backend'}) {
            # restart by livestatus
            my $name = $c->config->{'Thruk::Plugin::BP'}->{'result_backend'};
            my $peer = $c->{'db'}->get_peer_by_key($name);
            my $pkey = $peer->peer_key();
            die("no backend found by name ".$name) unless $peer;
            my $time = time();
            my $options = {
                'command' => sprintf("COMMAND [%d] RESTART_PROCESS", time()),
                'backend' => [ $pkey ],
            };
            $c->{'db'}->send_command( %{$options} );
            ($rc, $msg) = (0, 'business process saved and core restarted');
            Thruk::Utils::wait_after_reload($c, $pkey, $time);
        }
    } else {
        # discard file
        unlink($filename);
    }

    return($rc, $msg);
}

##########################################################

=head2 clean_function_args

    clean_function_args($args)

return clean args from a string

=cut
sub clean_function_args {
    my($args) = @_;
    return([]) unless defined $args;
    my @newargs = $args =~ m/('.*?'|".*?"|\d+)/gmx;
    for my $arg (@newargs) {
        $arg =~ s/^'(.*)'$/$1/mx;
        $arg =~ s/^"(.*)"$/$1/mx;
        if($arg =~ m/^(\d+|\d+.\d+)$/mx) {
            $arg = $arg + 0; # make it a real number
        }
    }
    return(\@newargs);
}

##########################################################

=head2 clean_orphaned_edit_files

  clean_orphaned_edit_files($c, [$threshold])

remove old edit files

=cut
sub clean_orphaned_edit_files {
    my($c, $threshold) = @_;
    $threshold = 86400 unless defined $threshold;
    my $base_folder = Thruk::BP::Utils::base_folder($c);
    for my $pattern (qw/edit runtime/) {
    my @files = glob($c->config->{'var_path'}.'/bp/*.tbp.'.$pattern);
        for my $file (@files) {
            $file =~ m/\/(\d+)\.tbp\.$pattern/mx;
            if($1 && !-e $base_folder.'/'.$1.'.tbp') {
                my($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,$atime,$mtime,$ctime,$blksize,$blocks) = stat($file);
                next if $mtime > (time() - $threshold);
                unlink($file);
            }
        }
    }
    return;
}

##########################################################

=head2 update_cron_file

  update_cron_file($c)

update reporting cronjobs

=cut
sub update_cron_file {
    my($c) = @_;

    my $rate = int($c->config->{'Thruk::Plugin::BP'}->{'refresh_interval'} || 1);
    if($rate <  1) { $rate =  1; }
    if($rate > 60) { $rate = 60; }

    # gather reporting send types from all reports
    my $cron_entries = [];
    my @files = glob(Thruk::BP::Utils::base_folder($c).'/*.tbp');
    if(scalar @files > 0) {
        open(my $fh, '>>', $c->config->{'var_path'}.'/cron.log');
        Thruk::Utils::IO::close($fh, $c->config->{'var_path'}.'/cron.log');
        my $cmd = sprintf("cd %s && %s '%s -a bpd' >/dev/null 2>>%s/cron.log",
                                $c->config->{'project_root'},
                                $c->config->{'thruk_shell'},
                                $c->config->{'thruk_bin'},
                                $c->config->{'var_path'},
                        );
        push @{$cron_entries}, ['* * * * *', $cmd] if $rate == 1;
        push @{$cron_entries}, ['*/'.$rate.' * * * *', $cmd] if $rate != 1;
    }

    Thruk::Utils::update_cron_file($c, 'business process', $cron_entries);
    return 1;
}

##########################################################

=head2 join_labels

    join_labels($nodes)

return string with joined labels

=cut
sub join_labels {
    my($nodes) = @_;
    my @labels;
    for my $n (@{$nodes}) {
        push @labels, $n->{'label'};
    }
    my $num = scalar @labels;
    if($num == 0) {
        return('');
    }
    if($num == 1) {
        return($labels[0]);
    }
    if($num == 2) {
        return($labels[0].' and '.$labels[1]);
    }
    my $last = pop @labels;
    return(join(', ', @labels).' and '.$last);
}

##########################################################

=head2 join_args

    join_args($args)

return string with joined args

=cut
sub join_args {
    my($args) = @_;
    my @arg;
    for my $a (@{$args}) {
        $a = '' unless defined $a;
        if($a =~ m/^(\d+|\d+\.\d+)$/mx) {
            push @arg, $a;
        } else {
            push @arg, "'".$a."'";
        }
    }
    return(join(', ', @arg));
}

##########################################################

=head2 state2text

    status2text($state)

return string of given state

=cut
sub state2text {
    my($nr) = @_;
    if($nr == 0) { return 'OK'; }
    if($nr == 1) { return 'WARNING'; }
    if($nr == 2) { return 'CRITICAL'; }
    if($nr == 3) { return 'UNKOWN'; }
    if($nr == 4) { return 'PENDING'; }
    return;
}

##########################################################

=head2 merge_obj_hash

    merge_obj_hash($hash, $data)

merge objects hash with more objects

=cut
sub merge_obj_hash {
    my($hash, $data) = @_;

    if(defined $data->{'hosts'}) {
        for my $hostname (keys %{$data->{'hosts'}}) {
            my $host = $data->{'hosts'}->{$hostname};
            $hash->{'hosts'}->{$hostname} = $host;
        }
    }

    if(defined $data->{'services'}) {
        for my $hostname (keys %{$data->{'services'}}) {
            for my $description (keys %{$data->{'services'}->{$hostname}}) {
                my $service = $data->{'services'}->{$hostname}->{$description};
                $hash->{'services'}->{$hostname}->{$description} = $service;
            }
        }
    }
    return($hash);
}

##########################################################

=head2 clean_nasty

    clean_nasty($string)

clean nasty chars from string

=cut
sub clean_nasty {
    my($str) = @_;
    $str =~ s#[`~!\$%^&*\|'"<>\?,\(\)=]*##gmxo;
    return($str);
}

##########################################################

=head2 base_folder

    base_folder($c)

return base folder of business process files

=cut
sub base_folder {
    my($c) = @_;
    if($ENV{'CATALYST_CONFIG'}) {
        return($ENV{'CATALYST_CONFIG'}.'/bp');
    }
    return($c->config->{'home'}.'/bp');
}

##########################################################

=head1 AUTHOR

Sven Nierlein, 2009-2014, <sven@nierlein.org>

=head1 LICENSE

This library is free software, you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

1;

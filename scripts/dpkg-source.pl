#! /usr/bin/perl
# vim: set et sw=4 ts=8
#
# dpkg-source
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

use strict;
use warnings;

use Dpkg;
use Dpkg::Gettext;
use Dpkg::ErrorHandling;
use Dpkg::Arch qw(debarch_eq);
use Dpkg::Deps;
use Dpkg::Compression;
use Dpkg::Conf;
use Dpkg::Control::Info;
use Dpkg::Control::Fields;
use Dpkg::Substvars;
use Dpkg::Version;
use Dpkg::Vars;
use Dpkg::Changelog::Parse;
use Dpkg::Source::Compressor;
use Dpkg::Source::Package;
use Dpkg::Vendor qw(run_vendor_hook);

use File::Spec;

textdomain("dpkg-dev");

my $varlistfile;
my $controlfile;
my $changelogfile;
my $changelogformat;

my @build_formats = ("1.0", "3.0 (quilt)", "3.0 (native)");
my %options = (
    # Compression related
    compression => $Dpkg::Source::Compressor::default_compression,
    comp_level => $Dpkg::Source::Compressor::default_compression_level,
    comp_ext => $comp_ext{$Dpkg::Source::Compressor::default_compression},
    # Ignore files
    tar_ignore => [],
    diff_ignore_regexp => '',
    # Misc options
    copy_orig_tarballs => 1,
    no_check => 0,
    require_valid_signature => 0,
);

# Fields to remove/override
my %remove;
my %override;

my $substvars = Dpkg::Substvars->new();
my $tar_ignore_default_pattern_done;

my @options;
my @cmdline_options;
my @cmdline_formats;
while (@ARGV && $ARGV[0] =~ m/^-/) {
    $_ = shift(@ARGV);
    if (m/^-b$/) {
        setopmode('-b');
    } elsif (m/^-x$/) {
        setopmode('-x');
    } elsif (m/^--print-format$/) {
	setopmode('--print-format');
    } else {
	push @options, $_;
    }
}

my $dir;
if (defined($options{'opmode'}) &&
    $options{'opmode'} =~ /^(-b|--print-format)$/) {
    if (not scalar(@ARGV)) {
	usageerr(_g("%s needs a directory"), $options{'opmode'});
    }
    $dir = File::Spec->catdir(shift(@ARGV));
    stat($dir) || syserr(_g("cannot stat directory %s"), $dir);
    if (not -d $dir) {
	error(_g("directory argument %s is not a directory"), $dir);
    }
    my $conf = Dpkg::Conf->new();
    my $optfile = File::Spec->catfile($dir, "debian", "source", "options");
    $conf->load($optfile) if -f $optfile;
    # --format options are not allowed, they would take precedence
    # over real command line options, debian/source/format should be used
    # instead
    @$conf = grep { ! /^--format=/ } @$conf;
    if (@$conf) {
	info(_g("using options from %s: %s"), $optfile, "$conf")
	    unless $options{'opmode'} eq "--print-format";
	unshift @options, @$conf;
    }
}

while (@options) {
    $_ = shift(@options);
    if (m/^--format=(.*)$/) {
        push @cmdline_formats, $1;
    } elsif (m/^-(?:Z|-compression=)(.*)$/) {
	my $compression = $1;
	$options{'compression'} = $compression;
	$options{'comp_ext'} = $comp_ext{$compression};
	usageerr(_g("%s is not a supported compression"), $compression)
	    unless $comp_supported{$compression};
	Dpkg::Source::Compressor->set_default_compression($compression);
    } elsif (m/^-(?:z|-compression-level=)(.*)$/) {
	my $comp_level = $1;
	$options{'comp_level'} = $comp_level;
	usageerr(_g("%s is not a compression level"), $comp_level)
	    unless $comp_level =~ /^([1-9]|fast|best)$/;
	Dpkg::Source::Compressor->set_default_compression_level($comp_level);
    } elsif (m/^-c(.*)$/) {
        $controlfile = $1;
    } elsif (m/^-l(.*)$/) {
        $changelogfile = $1;
    } elsif (m/^-F([0-9a-z]+)$/) {
        $changelogformat = $1;
    } elsif (m/^-D([^\=:]+)[=:](.*)$/) {
        $override{$1} = $2;
    } elsif (m/^-U([^\=:]+)$/) {
        $remove{$1} = 1;
    } elsif (m/^-i(.*)$/) {
        $options{'diff_ignore_regexp'} = $1 ? $1 : $Dpkg::Source::Package::diff_ignore_default_regexp;
    } elsif (m/^-I(.+)$/) {
        push @{$options{'tar_ignore'}}, $1;
    } elsif (m/^-I$/) {
        unless ($tar_ignore_default_pattern_done) {
            push @{$options{'tar_ignore'}}, @Dpkg::Source::Package::tar_ignore_default_pattern;
            # Prevent adding multiple times
            $tar_ignore_default_pattern_done = 1;
        }
    } elsif (m/^--no-copy$/) {
        $options{'copy_orig_tarballs'} = 0;
    } elsif (m/^--no-check$/) {
        $options{'no_check'} = 1;
    } elsif (m/^--require-valid-signature$/) {
        $options{'require_valid_signature'} = 1;
    } elsif (m/^-V(\w[-:0-9A-Za-z]*)[=:](.*)$/) {
        $substvars->set($1, $2);
    } elsif (m/^-T(.*)$/) {
        $varlistfile = $1;
    } elsif (m/^-(h|-help)$/) {
        usage();
        exit(0);
    } elsif (m/^--version$/) {
        version();
        exit(0);
    } elsif (m/^-[EW]$/) {
        # Deprecated option
        warning(_g("-E and -W are deprecated, they are without effect"));
    } elsif (m/^-q$/) {
        report_options(quiet_warnings => 1);
        $options{'quiet'} = 1;
    } elsif (m/^--$/) {
        last;
    } else {
        push @cmdline_options, $_;
    }
}

unless (defined($options{'opmode'})) {
    usageerr(_g("need -x or -b"));
}

if ($options{'opmode'} =~ /^(-b|--print-format)$/) {

    $options{'ARGV'} = \@ARGV;

    $changelogfile ||= "$dir/debian/changelog";
    $controlfile ||= "$dir/debian/control";
    
    my %ch_options = (file => $changelogfile);
    $ch_options{"changelogformat"} = $changelogformat if $changelogformat;
    my $changelog = changelog_parse(%ch_options);
    my $control = Dpkg::Control::Info->new($controlfile);

    my $srcpkg = Dpkg::Source::Package->new(options => \%options);
    my $fields = $srcpkg->{'fields'};

    my @sourcearch;
    my %archadded;
    my @binarypackages;

    # Scan control info of source package
    my $src_fields = $control->get_source();
    foreach $_ (keys %{$src_fields}) {
	my $v = $src_fields->{$_};
	if (m/^Source$/i) {
	    set_source_package($v);
	    $fields->{$_} = $v;
	} elsif (m/^Uploaders$/i) {
	    ($fields->{$_} = $v) =~ s/[\r\n]/ /g; # Merge in a single-line
	} elsif (m/^Build-(Depends|Conflicts)(-Indep)?$/i) {
	    my $dep;
	    my $type = field_get_dep_type($_);
	    $dep = Dpkg::Deps::parse($v, union => $type eq 'union');
	    error(_g("error occurred while parsing %s"), $_) unless defined $dep;
	    my $facts = Dpkg::Deps::KnownFacts->new();
	    $dep->simplify_deps($facts);
	    $dep->sort() if $type eq 'union';
	    $fields->{$_} = $dep->dump();
	} else {
            field_transfer_single($src_fields, $fields);
	}
    }

    # Scan control info of binary packages
    foreach my $pkg ($control->get_packages()) {
	my $p = $pkg->{'Package'};
	push(@binarypackages,$p);
	foreach $_ (keys %{$pkg}) {
	    my $v = $pkg->{$_};
            if (m/^Architecture$/) {
                # Gather all binary architectures in one set. 'any' and 'all'
                # are special-cased as they need to be the only ones in the
                # current stanza if present.
                if (debarch_eq($v, 'any') || debarch_eq($v, 'all')) {
                    push(@sourcearch, $v) unless $archadded{$v}++;
                } else {
                    for my $a (split(/\s+/, $v)) {
                        error(_g("`%s' is not a legal architecture string"),
                              $a)
                            unless $a =~ /^[\w-]+$/;
                        error(_g("architecture %s only allowed on its " .
                                 "own (list for package %s is `%s')"),
                              $a, $p, $a)
                            if grep($a eq $_, 'any', 'all');
                        push(@sourcearch, $a) unless $archadded{$a}++;
                    }
                }
            } elsif (m/^Homepage$/) {
                # Do not overwrite the same field from the source entry
            } else {
                field_transfer_single($pkg, $fields);
            }
	}
    }
    if (grep($_ eq 'any', @sourcearch)) {
        # If we encounter one 'any' then the other arches become insignificant.
        @sourcearch = ('any');
    }
    $fields->{'Architecture'} = join(' ', @sourcearch);

    # Scan fields of dpkg-parsechangelog
    foreach $_ (keys %{$changelog}) {
        my $v = $changelog->{$_};

	if (m/^Source$/) {
	    set_source_package($v);
	    $fields->{$_} = $v;
	} elsif (m/^Version$/) {
	    my ($ok, $error) = version_check($v);
            error($error) unless $ok;
	    $fields->{$_} = $v;
	} elsif (m/^Maintainer$/i) {
            # Do not replace the field coming from the source entry
	} else {
            field_transfer_single($changelog, $fields);
	}
    }
    
    $fields->{'Binary'} = join(', ', @binarypackages);
    # Avoid overly long line (>~1000 chars) by splitting over multiple lines
    $fields->{'Binary'} =~ s/(.{980,}?), ?/$1,\n/g;

    # Generate list of formats to try
    my @try_formats = (@cmdline_formats);
    if (-e "$dir/debian/source/format") {
        open(FORMAT, "<", "$dir/debian/source/format") ||
            syserr(_g("cannot read %s"), "$dir/debian/source/format");
        my $format = <FORMAT>;
        chomp($format);
        close(FORMAT);
        push @try_formats, $format;
    }
    push @try_formats, @build_formats;
    # Try all suggested formats until one is acceptable
    foreach my $format (@try_formats) {
        $fields->{'Format'} = $format;
        $srcpkg->upgrade_object_type(); # Fails if format is unsupported
        my ($res, $msg) = $srcpkg->can_build($dir);
        last if $res;
        info(_g("source format `%s' discarded: %s"), $format, $msg)
	    unless $options{'opmode'} eq "--print-format";
    }
    if ($options{'opmode'} eq "--print-format") {
	print $fields->{'Format'} . "\n";
	exit(0);
    }
    info(_g("using source format `%s'"), $fields->{'Format'});

    # Parse command line options
    $srcpkg->init_options();
    $srcpkg->parse_cmdline_options(@cmdline_options);

    run_vendor_hook("before-source-build", $srcpkg);
    # Build the files (.tar.gz, .diff.gz, etc)
    $srcpkg->build($dir);

    # Write the .dsc
    my $dscname = $srcpkg->get_basename(1) . ".dsc";
    info(_g("building %s in %s"), $sourcepackage, $dscname);
    $substvars->parse($varlistfile) if $varlistfile && -e $varlistfile;
    $srcpkg->write_dsc(filename => $dscname,
		       remove => \%remove,
		       override => \%override,
		       substvars => $substvars);
    exit(0);

} elsif ($options{'opmode'} eq '-x') {

    # Check command line
    unless (scalar(@ARGV)) {
	usageerr(_g("-x needs at least one argument, the .dsc"));
    }
    if (scalar(@ARGV) > 2) {
	usageerr(_g("-x takes no more than two arguments"));
    }
    my $dsc = shift(@ARGV);
    if (-d $dsc) {
	usageerr(_g("-x needs the .dsc file as first argument, not a directory"));
    }

    # Create the object that does everything
    my $srcpkg = Dpkg::Source::Package->new(filename => $dsc,
					    options => \%options);

    # Parse command line options
    $srcpkg->parse_cmdline_options(@cmdline_options);

    # Decide where to unpack
    my $newdirectory = $srcpkg->get_basename();
    $newdirectory =~ s/_/-/g;
    if (@ARGV) {
	$newdirectory = File::Spec->catdir(shift(@ARGV));
	if (-e $newdirectory) {
	    error(_g("unpack target exists: %s"), $newdirectory);
	}
    }

    # Various checks before unpacking
    unless ($options{'no_check'}) {
        if ($srcpkg->is_signed()) {
            $srcpkg->check_signature();
        } else {
            if ($options{'require_valid_signature'}) {
                error(_g("%s doesn't contain a valid OpenPGP signature"), $dsc);
            } else {
                warning(_g("extracting unsigned source package (%s)"), $dsc);
            }
        }
        $srcpkg->check_checksums();
    }

    # Unpack the source package (delegated to Dpkg::Source::Package::*)
    info(_g("extracting %s in %s"), $srcpkg->{'fields'}{'Source'}, $newdirectory);
    $srcpkg->extract($newdirectory);

    exit(0);
}

sub setopmode {
    if (defined($options{'opmode'})) {
	usageerr(_g("only one of -x, -b or --print-format allowed, and only once"));
    }
    $options{'opmode'} = $_[0];
}

sub version {
    printf _g("Debian %s version %s.\n"), $progname, $version;

    print _g("
Copyright (C) 1996 Ian Jackson and Klee Dienes.
Copyright (C) 2008 Raphael Hertzog");

    print _g("
This is free software; see the GNU General Public Licence version 2 or
later for copying conditions. There is NO warranty.
");
}

sub usage {
    printf _g(
"Usage: %s [<option> ...] <command>

Commands:
  -x <filename>.dsc [<output-dir>]
                           extract source package.
  -b <dir>                 build source package.
  --print-format <dir>     print the source format that would be
                           used to build the source package.")
    . "\n\n" . _g(
"Build options:
  -c<controlfile>          get control info from this file.
  -l<changelogfile>        get per-version info from this file.
  -F<changelogformat>      force change log format.
  -V<name>=<value>         set a substitution variable.
  -T<varlistfile>          read variables here.
  -D<field>=<value>        override or add a .dsc field and value.
  -U<field>                remove a field.
  -q                       quiet mode.
  -i[<regexp>]             filter out files to ignore diffs of
                             (defaults to: '%s').
  -I[<pattern>]            filter out files when building tarballs
                             (defaults to: %s).
  -Z<compression>          select compression to use (defaults to '%s',
                             supported are: %s).
  -z<level>                compression level to use (defaults to '%d',
                             supported are: '1'-'9', 'best', 'fast')")
    . "\n\n" . _g(
"Extract options:
  --no-copy                don't copy .orig tarballs
  --no-check               don't check signature and checksums before unpacking
  --require-valid-signature abort if the package doesn't have a valid signature")
    . "\n\n" . _g(
"General options:
  -h, --help               show this help message.
      --version            show the version.")
    . "\n\n" . _g(
"More options are available but they depend on the source package format.
See dpkg-source(1) for more info.") . "\n",
    $progname,
    $Dpkg::Source::Package::diff_ignore_default_regexp,
    join(' ', map { "-I$_" } @Dpkg::Source::Package::tar_ignore_default_pattern),
    $Dpkg::Source::Compressor::default_compression, "@comp_supported",
    $Dpkg::Source::Compressor::default_compression_level;
}


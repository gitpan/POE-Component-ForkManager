use inc::Module::Install;

name		'POE-Component-ForkManager';

license		'perl';

all_from	'lib/POE/Component/ForkManager.pm';

requires	'POE';
requires	'POE::Pipe::TwoWay';
requires	'POE::Driver::SysRW';
requires	'POE::Filter::Block';
requires	'POE::Wheel::ReadWrite';

no_index	directory	=> 'examples';

auto_install;

WriteAll;

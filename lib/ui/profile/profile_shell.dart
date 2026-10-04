import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../models/household.dart';
import '../../services/profile_session_controller.dart';
import '../syren_theme.dart';
import 'home_tab.dart';
import 'me_tab.dart';
import 'profile_picker.dart';
import 'rooms_tab.dart';
import 'rules_tab.dart';
import 'setup_page.dart';
import 'syren_widgets.dart';

/// Starts and stops the distance sensor readings of this device.
class PositioningControls {
  const PositioningControls({required this.isMeasuring, required this.toggle});

  final bool Function() isMeasuring;
  final Future<void> Function() toggle;
}

/// Everything a profile screen needs to read state and send commands.
class ProfileContext {
  const ProfileContext({required this.controller, required this.positioning});

  final ProfileSessionController controller;
  final PositioningControls positioning;
}

/// Rebuilds its child with fresh household data whenever the server state changes.
class HouseholdBuilder extends StatelessWidget {
  const HouseholdBuilder({
    super.key,
    required this.controller,
    required this.builder,
  });

  final ProfileSessionController controller;
  final Widget Function(BuildContext context, Household household) builder;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final configuration = controller.configuration;
        if (configuration == null) {
          return const _Disconnected();
        }
        return builder(
          context,
          Household.from(
            configuration: configuration,
            catalogue: controller.catalogue,
            receivers: controller.receivers,
          ),
        );
      },
    );
  }
}

class _Disconnected extends StatelessWidget {
  const _Disconnected();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SyrenPage(
        children: [
          const BackLink('Back'),
          const Text('Lost the hub', style: SyrenText.title),
          Text(
            'The hub stopped sending its settings. Go back to reconnect.',
            style: SyrenText.lead,
          ),
          SyrenButton(
            'Back to start',
            onPressed: () =>
                Navigator.of(context).popUntil((route) => route.isFirst),
          ),
        ],
      ),
    );
  }
}

class ProfileShell extends StatefulWidget {
  const ProfileShell({
    super.key,
    required this.controller,
    required this.positioning,
  });

  final ProfileSessionController controller;
  final PositioningControls positioning;

  @override
  State<ProfileShell> createState() => _ProfileShellState();
}

class _ProfileShellState extends State<ProfileShell> {
  int tab = 0;

  ProfileContext get profile => ProfileContext(
    controller: widget.controller,
    positioning: widget.positioning,
  );

  void openAccount(Household household) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => AccountSheet(
        profile: profile,
        household: household,
        onSetup: () {
          Navigator.of(sheetContext).pop();
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (context) => SetupPage(profile: profile),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return HouseholdBuilder(
      controller: widget.controller,
      builder: (context, household) {
        final me = household.person(widget.controller.selectedId);
        if (me == null) {
          return Scaffold(body: ProfilePicker(profile: profile));
        }
        final avatar = Semantics(
          button: true,
          label: 'Profile and setup',
          child: GestureDetector(
            onTap: () => openAccount(household),
            child: PersonAvatar(me),
          ),
        );
        final pages = [
          HomeTab(
            profile: profile,
            household: household,
            avatar: avatar,
            onOpenRooms: () => setState(() => tab = 2),
          ),
          MeTab(profile: profile, household: household, me: me, avatar: avatar),
          RoomsTab(profile: profile, household: household, avatar: avatar),
          RulesTab(
            profile: profile,
            household: household,
            me: me,
            avatar: avatar,
          ),
        ];
        return Scaffold(
          body: Column(
            children: [
              if (!widget.controller.serverOnline) const _OfflineBanner(),
              Expanded(
                child: MediaQuery.removePadding(
                  context: context,
                  removeTop: !widget.controller.serverOnline,
                  child: pages[tab],
                ),
              ),
            ],
          ),
          bottomNavigationBar: _TabBar(
            index: tab,
            onSelected: (index) => setState(() => tab = index),
          ),
        );
      },
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: SyrenColors.warningBackground,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 10, 22, 10),
          child: Text(
            'The hub is offline. What you see may be out of date, and changes wait until it is back.',
            style: SyrenText.small.copyWith(
              color: SyrenColors.warning,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

const _tabs = [
  (label: 'Home', icon: Icons.home_outlined, selectedIcon: Icons.home),
  (label: 'Me', icon: Icons.person_outline, selectedIcon: Icons.person),
  (
    label: 'Rooms',
    icon: Icons.speaker_group_outlined,
    selectedIcon: Icons.speaker_group,
  ),
  (label: 'Rules', icon: Icons.tune_outlined, selectedIcon: Icons.tune),
];

/// The iOS style tab bar from the designs, or a Material bar on Android.
class _TabBar extends StatelessWidget {
  const _TabBar({required this.index, required this.onSelected});

  final int index;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return NavigationBar(
        selectedIndex: index,
        onDestinationSelected: onSelected,
        destinations: [
          for (final tab in _tabs)
            NavigationDestination(
              icon: Icon(tab.icon),
              selectedIcon: Icon(tab.selectedIcon),
              label: tab.label,
            ),
        ],
      );
    }
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: SyrenColors.softCard,
        border: Border(top: BorderSide(color: SyrenColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              for (final (position, tab) in _tabs.indexed)
                Expanded(
                  child: Semantics(
                    selected: position == index,
                    button: true,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => onSelected(position),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              position == index ? tab.selectedIcon : tab.icon,
                              size: 24,
                              color: position == index
                                  ? SyrenColors.ink
                                  : SyrenColors.muted,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              tab.label,
                              style: TextStyle(
                                fontFamily: SyrenFonts.sans,
                                fontSize: 11,
                                fontWeight: position == index
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                                color: position == index
                                    ? SyrenColors.ink
                                    : SyrenColors.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The avatar menu: switch profile, add one, or open setup.
class AccountSheet extends StatefulWidget {
  const AccountSheet({
    super.key,
    required this.profile,
    required this.household,
    required this.onSetup,
  });

  final ProfileContext profile;
  final Household household;
  final VoidCallback onSetup;

  @override
  State<AccountSheet> createState() => _AccountSheetState();
}

class _AccountSheetState extends State<AccountSheet> with CommandRunner {
  @override
  Widget build(BuildContext context) {
    final controller = widget.profile.controller;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const MonoLabel('Switch profile'),
            const SizedBox(height: 8),
            for (final person in widget.household.people)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                leading: PersonAvatar(person, size: 34),
                title: Text(person.name, style: SyrenText.cardTitle),
                subtitle: Text(
                  widget.household.activity(person.id) ?? ' ',
                  style: SyrenText.small,
                ),
                trailing: person.id == controller.selectedId
                    ? const Icon(Icons.check, color: SyrenColors.ink)
                    : null,
                onTap: busy || person.id == controller.selectedId
                    ? null
                    : () => run(() async {
                        await controller.select(person.id);
                        if (context.mounted) Navigator.of(context).pop();
                      }),
              ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: SyrenColors.chip,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.add, color: SyrenColors.muted),
              ),
              title: const Text('New profile', style: SyrenText.cardTitle),
              onTap: busy
                  ? null
                  : () => run(() async {
                      final navigator = Navigator.of(context);
                      final created = await createProfile(context, controller);
                      if (created == null) return;
                      navigator.pop();
                      await navigator.push(
                        MaterialPageRoute<void>(
                          builder: (context) => SpotifyLinkPage(
                            profile: widget.profile,
                            onboarding: true,
                          ),
                        ),
                      );
                    }),
            ),
            const Divider(color: SyrenColors.divider),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: const Icon(
                Icons.settings_outlined,
                color: SyrenColors.ink,
              ),
              title: const Text('Setup', style: SyrenText.cardTitle),
              subtitle: const Text(
                'Speakers, positioning, hub connection',
                style: SyrenText.small,
              ),
              onTap: widget.onSetup,
            ),
          ],
        ),
      ),
    );
  }
}

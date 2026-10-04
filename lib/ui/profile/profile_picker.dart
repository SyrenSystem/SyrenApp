import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/household.dart';
import '../../services/profile_session_controller.dart';
import '../syren_theme.dart';
import 'profile_shell.dart';
import 'syren_widgets.dart';

Future<String?> askName(
  BuildContext context,
  String title, [
  String initial = '',
]) async {
  final field = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: field,
        autofocus: true,
        maxLength: 100,
        decoration: const InputDecoration(border: UnderlineInputBorder()),
        onSubmitted: (value) {
          if (value.trim().isNotEmpty) Navigator.pop(context, value.trim());
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (field.text.trim().isNotEmpty) {
              Navigator.pop(context, field.text.trim());
            }
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
  field.dispose();
  return result;
}

/// Asks for a name, creates the profile with the default rules and selects it.
Future<String?> createProfile(
  BuildContext context,
  ProfileSessionController controller,
) async {
  final name = await askName(context, 'New profile');
  if (name == null) return null;
  final identity =
      '${controller.instanceId}-${DateTime.now().microsecondsSinceEpoch}';
  await controller.saveProfile({
    'id': identity,
    'name': name,
    'followMe': false,
    'sourcePriority': ['spotify', 'laptop', 'casting'],
    'overlap': <Object>[],
  });
  await controller.select(identity);
  return identity;
}

/// "Who's listening?": pick a household profile or make a new one.
class ProfilePicker extends StatefulWidget {
  const ProfilePicker({super.key, required this.profile});

  final ProfileContext profile;

  @override
  State<ProfilePicker> createState() => _ProfilePickerState();
}

class _ProfilePickerState extends State<ProfilePicker> with CommandRunner {
  String? chosen;

  @override
  Widget build(BuildContext context) {
    final controller = widget.profile.controller;
    return HouseholdBuilder(
      controller: controller,
      builder: (context, household) {
        final people = household.people;
        final pick =
            people.where((person) => person.id == chosen).firstOrNull ??
            people.firstOrNull;
        return SyrenPage(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 28),
          spacing: 22,
          children: [
            const Text("Who's listening?", style: SyrenText.hero),
            LayoutBuilder(
              builder: (context, constraints) {
                final width = (constraints.maxWidth - 12) / 2;
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final tile in [
                      for (final person in people)
                        _ProfileTile(
                          person: person,
                          status: household.activity(person.id),
                          selected: person.id == pick?.id,
                          onTap: () => setState(() => chosen = person.id),
                        ),
                      _NewProfileTile(
                        onTap: busy
                            ? null
                            : () => run(() async {
                                final navigator = Navigator.of(context);
                                final created = await createProfile(
                                  context,
                                  controller,
                                );
                                if (created == null) return;
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
                    ])
                      SizedBox(width: width, child: tile),
                  ],
                );
              },
            ),
            Text(
              'Each profile has its own Spotify account, source order and Follow me. Nobody takes over anyone else by accident.',
              style: SyrenText.lead.copyWith(fontSize: 14),
            ),
            if (!controller.serverOnline)
              const NoteBox(
                'The hub is offline. You can pick a profile once it is back.',
              ),
            if (pick != null)
              SyrenButton(
                'Continue as ${pick.name}',
                onPressed: busy || !controller.serverOnline
                    ? null
                    : () => run(() => controller.select(pick.id)),
              ),
          ],
        );
      },
    );
  }
}

class _ProfileTile extends StatelessWidget {
  const _ProfileTile({
    required this.person,
    required this.status,
    required this.selected,
    required this.onTap,
  });

  final Person person;
  final String? status;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: SyrenColors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: selected
              ? const BorderSide(color: SyrenColors.ink, width: 2)
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                PersonAvatar(person, size: 60),
                const SizedBox(height: 10),
                Text(
                  person.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SyrenText.cardTitle,
                ),
                const SizedBox(height: 2),
                Text(
                  status ?? ' ',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SyrenText.small.copyWith(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NewProfileTile extends StatelessWidget {
  const _NewProfileTile({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: CustomPaint(
        painter: _DashedBorder(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 60,
                height: 60,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: SyrenColors.chip,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.add,
                  size: 28,
                  color: SyrenColors.muted,
                ),
              ),
              const SizedBox(height: 10),
              const Text('New profile', style: SyrenText.cardTitle),
              const SizedBox(height: 2),
              Text(
                'Pick a name',
                style: SyrenText.small.copyWith(fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DashedBorder extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFC9C2B6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final outline = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Offset.zero & size,
          const Radius.circular(20),
        ).deflate(0.75),
      );
    for (final metric in outline.computeMetrics()) {
      for (var start = 0.0; start < metric.length; start += 10) {
        canvas.drawPath(metric.extractPath(start, start + 5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Explains that music is picked in Spotify, then links the account.
class SpotifyLinkPage extends StatefulWidget {
  const SpotifyLinkPage({
    super.key,
    required this.profile,
    this.onboarding = false,
  });

  final ProfileContext profile;
  final bool onboarding;

  @override
  State<SpotifyLinkPage> createState() => _SpotifyLinkPageState();
}

class _SpotifyLinkPageState extends State<SpotifyLinkPage> with CommandRunner {
  @override
  void initState() {
    super.initState();
    // A finished attempt may belong to another profile, so only a running one stays.
    final controller = widget.profile.controller;
    if (!{'starting', 'pair'}.contains(controller.linkStatus?['status'])) {
      controller.linkStatus = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.profile.controller;
    return HouseholdBuilder(
      controller: controller,
      builder: (context, household) {
        final me = household.person(controller.selectedId);
        if (me == null) return const Scaffold();
        final linked = me.profile!['spotifyAccountId'] != null;
        final others = household.people
            .where((person) => person.id != me.id)
            .map((person) => person.name)
            .toList();
        final status = controller.linkStatus;
        final steps = [
          'You choose music **in Spotify**, like you do now.',
          'Pick **SyrenSystem** as the device and it plays in your rooms. Each room also shows up as SyrenSystem · room.',
          others.isEmpty
              ? 'Everyone else keeps their own account and music.'
              : '${others.join(' and ')} keep${others.length == 1 ? 's' : ''} their own account and music.',
        ];
        return Scaffold(
          body: SyrenPage(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
            spacing: 22,
            children: [
              if (widget.onboarding)
                const MonoLabel('Step 2 of 2')
              else
                const BackLink('Me'),
              Text(
                linked
                    ? 'Spotify is linked, ${me.name}'
                    : 'Link your Spotify, ${me.name}',
                style: SyrenText.hero,
              ),
              RowsCard(
                rows: [
                  for (final (index, step) in steps.indexed)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '0${index + 1}',
                            style: SyrenText.mono.copyWith(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: SyrenColors.accent,
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(child: _Emphasis(step)),
                        ],
                      ),
                    ),
                ],
              ),
              if (status != null && !linked) _LinkStatus(status: status),
              if (linked) ...[
                SyrenButton(
                  'Done',
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                SyrenButton(
                  'Unlink this Spotify account',
                  kind: ButtonKind.link,
                  onPressed: busy
                      ? null
                      : () => run(
                          () => controller.command('unlink', {
                            'profileId': me.id,
                          }),
                        ),
                ),
              ] else ...[
                SyrenButton(
                  status == null ? 'Continue with Spotify' : 'Get a new link',
                  kind: ButtonKind.spotify,
                  onPressed: busy ? null : () => run(controller.linkSpotify),
                ),
                SyrenButton(
                  "Not now, I'll only use PC audio",
                  kind: ButtonKind.link,
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                const Text(
                  'Needs Spotify Premium',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: SyrenFonts.sans,
                    fontSize: 12,
                    color: SyrenColors.muted,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _LinkStatus extends StatelessWidget {
  const _LinkStatus({required this.status});

  final Map<String, dynamic> status;

  @override
  Widget build(BuildContext context) {
    final url = status['url'] as String?;
    final (title, detail, good) = switch (status['status']) {
      'pair' => (
        'Open this link',
        'Use a browser that is signed in to your Spotify account.',
        true,
      ),
      'linked' => ('Linked', 'Pick SyrenSystem in Spotify to start.', true),
      'expired' => ('The link expired', 'Get a new link and try again.', false),
      'rejected' => (
        'Spotify was not linked',
        '${status['error'] ?? 'The hub turned the account down.'}',
        false,
      ),
      'failed' => ('Linking failed', 'Get a new link and try again.', false),
      _ => ('Asking the hub for a link…', 'This takes a few seconds.', true),
    };
    return SyrenCard(
      color: good ? SyrenColors.card : SyrenColors.badRow,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: SyrenText.label),
          const SizedBox(height: 4),
          Text(detail, style: SyrenText.small),
          if (url != null) ...[
            const SizedBox(height: 10),
            SelectableText(
              url,
              style: SyrenText.mono.copyWith(
                fontSize: 12,
                color: SyrenColors.ink,
              ),
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('Copy link'),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: url));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Link copied')),
                    );
                  }
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Renders text where **words** are bold.
class _Emphasis extends StatelessWidget {
  const _Emphasis(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final parts = text.split('**');
    return Text.rich(
      TextSpan(
        style: SyrenText.body,
        children: [
          for (final (index, part) in parts.indexed)
            TextSpan(
              text: part,
              style: index.isOdd
                  ? const TextStyle(fontWeight: FontWeight.w700)
                  : null,
            ),
        ],
      ),
    );
  }
}

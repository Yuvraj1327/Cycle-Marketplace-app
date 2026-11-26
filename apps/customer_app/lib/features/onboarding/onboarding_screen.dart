import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import 'onboarding_store.dart';

class _OnboardingPageData {
  const _OnboardingPageData({
    required this.image,
    required this.title,
    required this.description,
  });
  final String image;
  final String title;
  final String description;
}

const _pages = <_OnboardingPageData>[
  _OnboardingPageData(
    image: 'assets/images/onboarding/onboarding_1_find_your_cycle.jpg',
    title: 'Find Your Perfect Cycle',
    description: 'Discover new and pre-owned bicycles for every ride.',
  ),
  _OnboardingPageData(
    image: 'assets/images/onboarding/onboarding_2_spare_parts.jpg',
    title: 'Everything Your Cycle Needs',
    description:
        'Shop quality spare parts, accessories and cycling essentials in one place.',
  ),
  _OnboardingPageData(
    image: 'assets/images/onboarding/onboarding_3_expert_servicing.jpg',
    title: 'Expert Cycle Servicing',
    description:
        'Book professional repairs and maintenance to keep your cycle in perfect condition.',
  ),
  _OnboardingPageData(
    image: 'assets/images/onboarding/onboarding_4_doorstep_service.jpg',
    title: 'Service at Your Doorstep',
    description:
        'Schedule convenient cycle pickup and delivery without leaving your home.',
  ),
];

/// Four-page first-launch introduction. Finishing or skipping it is remembered, so it is only ever shown once.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});
  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  static const _slide = Duration(milliseconds: 350);
  final _controller = PageController();
  int _index = 0;
  bool _imagesPrecached = false;

  bool get _isLast => _index == _pages.length - 1;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_imagesPrecached) return;
    _imagesPrecached = true;
    for (final p in _pages) {
      precacheImage(AssetImage(p.image), context);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _goTo(int page) =>
      _controller.animateToPage(page, duration: _slide, curve: Curves.easeOut);

  /// Skip and Get Started both end here: remember it, then hand over to the existing auth flow.
  Future<void> _finish() async {
    final router = GoRouter.of(context);
    await ref.read(onboardingCompletedProvider.notifier).complete();
    router.go('/login');
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return PopScope(
      canPop: _index == 0, // Android back steps to the previous page first
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goTo(_index - 1);
      },
      child: MediaQuery(
        // Keeps the fixed bottom controls from overflowing at extreme accessibility font sizes.
        data: mq.copyWith(textScaler: mq.textScaler.clamp(maxScaleFactor: 1.3)),
        child: Scaffold(
          backgroundColor: Colors.white,
          body: Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    PageView.builder(
                      controller: _controller,
                      itemCount: _pages.length,
                      onPageChanged: (i) => setState(() => _index = i),
                      itemBuilder: (_, i) => _OnboardingPage(data: _pages[i]),
                    ),
                    Positioned(
                      top: mq.padding.top + 12,
                      right: 16,
                      child: AnimatedOpacity(
                        opacity: _isLast ? 0 : 1,
                        duration: const Duration(milliseconds: 200),
                        child: IgnorePointer(
                          ignoring: _isLast,
                          child: _SkipButton(onPressed: _finish),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  24,
                  4,
                  24,
                  mq.padding.bottom > 0 ? mq.padding.bottom : 20,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _PageIndicator(count: _pages.length, index: _index),
                        const SizedBox(height: 20),
                        FilledButton(
                          key: const Key('onboarding-primary'),
                          onPressed: _isLast
                              ? _finish
                              : () => _goTo(_index + 1),
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 200),
                            child: Row(
                              key: ValueKey(_isLast),
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(_isLast ? 'Get Started' : 'Next'),
                                const SizedBox(width: 8),
                                const Icon(
                                  Icons.arrow_forward_rounded,
                                  size: 20,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
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

class _OnboardingPage extends StatelessWidget {
  const _OnboardingPage({required this.data});
  final _OnboardingPageData data;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      children: [
        Expanded(
          child: SizedBox(
            width: double.infinity,
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(32),
              ),
              child: Image.asset(
                data.image,
                fit: BoxFit.cover, // fills the area, crops (never stretches)
                filterQuality: FilterQuality.high,
                excludeFromSemantics: true,
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 12),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    data.title,
                    textAlign: TextAlign.center,
                    style: text.headlineSmall?.copyWith(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      color: AppColors.primary,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    data.description,
                    textAlign: TextAlign.center,
                    style: text.bodyLarge?.copyWith(
                      color: AppColors.muted,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SkipButton extends StatelessWidget {
  const _SkipButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: .85),
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const Key('onboarding-skip'),
        onTap: onPressed,
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          child: Text(
            'Skip',
            style: TextStyle(
              color: AppColors.primary,
              fontWeight: FontWeight.w700,
              fontSize: 14,
            ),
          ),
        ),
      ),
    );
  }
}

class _PageIndicator extends StatelessWidget {
  const _PageIndicator({required this.count, required this.index});
  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Page ${index + 1} of $count',
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < count; i++)
              AnimatedContainer(
                key: Key('onboarding-dot-$i'),
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOut,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                height: 8,
                width: i == index ? 28 : 8,
                decoration: BoxDecoration(
                  color: i == index
                      ? AppColors.primary
                      : AppColors.mint.withValues(alpha: .6),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

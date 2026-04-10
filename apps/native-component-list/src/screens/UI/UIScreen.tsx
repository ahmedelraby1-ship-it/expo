import { optionalRequire } from '../../navigation/routeBuilder';
import ComponentListScreen, { componentScreensToListElements } from '../ComponentListScreen';

// Community drop-in replacement components that support web
const CommunityScreens = [
  {
    name: 'Community BottomSheet replacement',
    route: 'ui/community-bottomsheet',
    options: {},
    getComponent() {
      return optionalRequire(() => require('./CommunityBottomSheetScreen'));
    },
  },
];

export const UIScreens = [...CommunityScreens];

export default function UIScreen() {
  return <ComponentListScreen apis={componentScreensToListElements(CommunityScreens)} />;
}

UIScreen.navigationOptions = {
  title: 'Expo UI',
};

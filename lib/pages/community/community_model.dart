import '/components/file_card/file_card_widget.dart';
import '/components/folder_card/folder_card_widget.dart';
import '/components/nav_menu/nav_menu_widget.dart';
import '/flutter_flow/flutter_flow_util.dart';
import 'community_widget.dart' show CommunityWidget;
import 'package:flutter/material.dart';

class CommunityModel extends FlutterFlowModel<CommunityWidget> {
  ///  State fields for stateful widgets in this page.

  // Model for NavMenu component.
  late NavMenuModel navMenuModel;
  // State field(s) for TextField widget.
  FocusNode? textFieldFocusNode;
  TextEditingController? textController;
  String? Function(BuildContext, String?)? textControllerValidator;
  // Model for FolderCard component.
  late FolderCardModel folderCardModel1;
  // Model for FolderCard component.
  late FolderCardModel folderCardModel2;
  // Model for FolderCard component.
  late FolderCardModel folderCardModel3;
  // Model for FolderCard component.
  late FolderCardModel folderCardModel4;
  // Model for FileCard component.
  late FileCardModel fileCardModel1;
  // Model for FileCard component.
  late FileCardModel fileCardModel2;
  // Model for FileCard component.
  late FileCardModel fileCardModel3;
  // Model for FileCard component.
  late FileCardModel fileCardModel4;
  // Model for FileCard component.
  late FileCardModel fileCardModel5;

  @override
  void initState(BuildContext context) {
    navMenuModel = createModel(context, () => NavMenuModel());
    folderCardModel1 = createModel(context, () => FolderCardModel());
    folderCardModel2 = createModel(context, () => FolderCardModel());
    folderCardModel3 = createModel(context, () => FolderCardModel());
    folderCardModel4 = createModel(context, () => FolderCardModel());
    fileCardModel1 = createModel(context, () => FileCardModel());
    fileCardModel2 = createModel(context, () => FileCardModel());
    fileCardModel3 = createModel(context, () => FileCardModel());
    fileCardModel4 = createModel(context, () => FileCardModel());
    fileCardModel5 = createModel(context, () => FileCardModel());
  }

  @override
  void dispose() {
    navMenuModel.dispose();
    textFieldFocusNode?.dispose();
    textController?.dispose();

    folderCardModel1.dispose();
    folderCardModel2.dispose();
    folderCardModel3.dispose();
    folderCardModel4.dispose();
    fileCardModel1.dispose();
    fileCardModel2.dispose();
    fileCardModel3.dispose();
    fileCardModel4.dispose();
    fileCardModel5.dispose();
  }
}

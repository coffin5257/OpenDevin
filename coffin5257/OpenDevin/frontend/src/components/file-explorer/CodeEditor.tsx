import React from 'react';
import { useSelector } from 'react-redux';
import { RootState } from '#/store';
import { I18nKey } from '#/i18n/declaration';
import { useTranslation } from 'react-i18next';
import { VscCode, VscSave } from 'react-icons/vsc';
import Button from '#/components/Button';
import Editor from '@monaco-editor/react';
import MediaViewer from '#/components/MediaViewer';
import FileExplorer from './FileExplorer';
import { isFileTypeSupported } from '#/services/fileService';

const CodeEditor: React.FC = () => {
  const { t } = useTranslation();
  const selectedFileName = useSelector((state: RootState) => state.code.path);
  const hasUnsavedChanges = useSelector((state: RootState) => state.code.hasUnsavedChanges);
  const saveStatus = useSelector((state: RootState) => state.code.saveStatus);
  const isEditingAllowed = useSelector((state: RootState) => state.code.isEditingAllowed);

  const handleSave = () => {
    // Implement save logic here
  };

  const getSaveButtonColor = () => {
    if (saveStatus === 'saving') return 'bg-yellow-500';
    if (hasUnsavedChanges) return 'bg-red-500';
    return 'bg-green-500';
  };

  const renderFileViewer = () => {
    if (!selectedFileName) {
      return (
        <div className="flex flex-col items-center text-neutral-400">
          <VscCode size={100} />
          {t(I18nKey.CODE_EDITOR$EMPTY_MESSAGE)}
        </div>
      );
    }

    if (isFileTypeSupported(selectedFileName)) {
      return <MediaViewer filePath={selectedFileName} />;
    }

    return (
      <div className="text-red-500">
        {t(I18nKey.CODE_EDITOR$UNSUPPORTED_FILE_TYPE_MESSAGE)}
      </div>
    );
  };

  return (
    <div className="flex h-full w-full bg-neutral-900 transition-all duration-500 ease-in-out relative">
      <FileExplorer />
      <div className="flex flex-col min-h-0 w-full">
        <div className="flex justify-between items-center border-b border-neutral-600 mb-4">
          <div className="flex items-center mr-2">
            <Button
              onClick={handleSave}
              className={`${getSaveButtonColor()} text-white transition-colors duration-300 mr-2`}
              size="sm"
              startContent={<VscSave />}
              disabled={saveStatus === 'saving' || !isEditingAllowed}
            >
              {saveStatus === 'saving'
                ? t(I18nKey.CODE_EDITOR$SAVING_LABEL)
                : t(I18nKey.CODE_EDITOR$SAVE_LABEL)}
            </Button>
          </div>
        </div>
        <div className="flex grow items-center justify-center">
          {renderFileViewer()}
        </div>
      </div>
    </div>
  );
};

export default CodeEditor;


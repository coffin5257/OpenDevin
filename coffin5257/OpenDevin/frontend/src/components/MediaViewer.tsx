import React from 'react';

interface MediaViewerProps {
  filePath: string;
}

const MediaViewer: React.FC<MediaViewerProps> = ({ filePath }) => {
  const fileExtension = filePath.split('.').pop()?.toLowerCase();

  switch (fileExtension) {
    case 'jpg':
    case 'jpeg':
    case 'png':
      return <img src={filePath} alt="Media content" className="w-full h-auto" />;
    case 'mp4':
      return (
        <video controls className="w-full h-auto">
          <source src={filePath} type="video/mp4" />
          Your browser does not support the video tag.
        </video>
      );
    case 'pdf':
      return (
        <iframe
          src={filePath}
          title="PDF Document"
          className="w-full h-full"
          style={{ minHeight: '500px' }}
        />
      );
    default:
      return (
        <div className="text-red-500">
          Unsupported file type. Please select a jpg, png, mp4, or pdf file.
        </div>
      );
  }
};

export default MediaViewer;

